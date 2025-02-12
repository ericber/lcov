#!/usr/bin/perl -w
#
#   Copyright (c) International Business Machines  Corp., 2002,2012
#
#   This program is free software;  you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or (at
#   your option) any later version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY;  without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   General Public License for more details.                 
#
#   You should have received a copy of the GNU General Public License
#   along with this program;  if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
#
# lcov
#
#   This is a wrapper script which provides a single interface for accessing
#   LCOV coverage data.
#
#
# History:
#   2002-08-29 created by Peter Oberparleiter <Peter.Oberparleiter@de.ibm.com>
#                         IBM Lab Boeblingen
#   2002-09-05 / Peter Oberparleiter: implemented --kernel-directory +
#                multiple directories
#   2002-10-16 / Peter Oberparleiter: implemented --add-tracefile option
#   2002-10-17 / Peter Oberparleiter: implemented --extract option
#   2002-11-04 / Peter Oberparleiter: implemented --list option
#   2003-03-07 / Paul Larson: Changed to make it work with the latest gcov 
#                kernel patch.  This will break it with older gcov-kernel
#                patches unless you change the value of $gcovmod in this script
#   2003-04-07 / Peter Oberparleiter: fixed bug which resulted in an error
#                when trying to combine .info files containing data without
#                a test name
#   2003-04-10 / Peter Oberparleiter: extended Paul's change so that LCOV
#                works both with the new and the old gcov-kernel patch
#   2003-04-10 / Peter Oberparleiter: added $gcov_dir constant in anticipation
#                of a possible move of the gcov kernel directory to another
#                file system in a future version of the gcov-kernel patch
#   2003-04-15 / Paul Larson: make info write to STDERR, not STDOUT
#   2003-04-15 / Paul Larson: added --remove option
#   2003-04-30 / Peter Oberparleiter: renamed --reset to --zerocounters
#                to remove naming ambiguity with --remove
#   2003-04-30 / Peter Oberparleiter: adjusted help text to include --remove
#   2003-06-27 / Peter Oberparleiter: implemented --diff
#   2003-07-03 / Peter Oberparleiter: added line checksum support, added
#                --no-checksum
#   2003-12-11 / Laurent Deniel: added --follow option
#   2004-03-29 / Peter Oberparleiter: modified --diff option to better cope with
#                ambiguous patch file entries, modified --capture option to use
#                modprobe before insmod (needed for 2.6)
#   2004-03-30 / Peter Oberparleiter: added --path option
#   2004-08-09 / Peter Oberparleiter: added configuration file support
#   2008-08-13 / Peter Oberparleiter: added function coverage support
#   2014-09-12 / VaL Doroshchuk: ported to Windows
#

use strict;
use File::Basename;
use File::Path;
use File::Find;
use File::Temp qw /tempdir/;
use File::Spec::Functions qw /abs2rel canonpath catdir catfile catpath
                  file_name_is_absolute rootdir splitdir splitpath/;
use Getopt::Long;
use Cwd qw /abs_path getcwd/;


# Global constants
our $lcov_version    = 'LCOV version 1.11';
our $lcov_url        = "http://ltp.sourceforge.net/coverage/lcov.php";
our $tool_name        = basename($0);
our $perl_exe         = $ENV{'PERL_EXE'};;

# Directory containing gcov kernel files
our $gcov_dir;

# Where to create temporary directories
our $tmp_dir;

# Internal constants
our $GKV_PROC = 0;    # gcov-kernel data in /proc via external patch
our $GKV_SYS = 1;    # gcov-kernel data in /sys via vanilla 2.6.31+
our @GKV_NAME = ( "external", "upstream" );
our $pkg_gkv_file = ".gcov_kernel_version";
our $pkg_build_file = ".build_directory";

our $BR_BLOCK        = 0;
our $BR_BRANCH        = 1;
our $BR_TAKEN        = 2;
our $BR_VEC_ENTRIES    = 3;
our $BR_VEC_WIDTH    = 32;
our $BR_VEC_MAX        = vec(pack('b*', 1 x $BR_VEC_WIDTH), 0, $BR_VEC_WIDTH);

# Branch data combination types
our $BR_SUB = 0;
our $BR_ADD = 1;

# Prototypes
sub print_usage(*);
sub check_options();
sub userspace_reset();
sub userspace_capture();
sub kernel_reset();
sub kernel_capture();
sub kernel_capture_initial();
sub package_capture();
sub add_traces();
sub read_info_file($);
sub get_info_entry($);
sub set_info_entry($$$$$$$$$;$$$$$$);
sub add_counts($$);
sub merge_checksums($$$);
sub combine_info_entries($$$);
sub combine_info_files($$);
sub write_info_file(*$);
sub extract();
sub remove();
sub list();
sub get_common_filename($$);
sub read_diff($);
sub diff();
sub system_no_output($@);
sub read_config($);
sub apply_config($);
sub info(@);
sub create_temp_dir();
sub transform_pattern($);
sub warn_handler($);
sub die_handler($);
sub abort_handler($);
sub temp_cleanup();
sub setup_gkv();
sub get_overall_line($$$$);
sub print_overall_rate($$$$$$$$$);
sub lcov_geninfo(@);
sub create_package($$$;$);
sub get_func_found_and_hit($);
sub br_ivec_get($$);
sub summary();
sub rate($$;$$$);

# Global variables & initialization
our @directory;        # Specifies where to get coverage data from
our @kernel_directory;    # If set, captures only from specified kernel subdirs
our @add_tracefile;    # If set, reads in and combines all files in list
our $list;        # If set, list contents of tracefile
our $extract;        # If set, extracts parts of tracefile
our $remove;        # If set, removes parts of tracefile
our $diff;        # If set, modifies tracefile according to diff
our $reset;        # If set, reset all coverage data to zero
our $capture;        # If set, capture data
our $output_filename;    # Name for file to write coverage data to
our $test_name = "";    # Test case name
our $quiet = "";    # If set, suppress information messages
our $help;        # Help option flag
our $version;        # Version option flag
our $convert_filenames;    # If set, convert filenames when applying diff
our $strip;        # If set, strip leading directories when applying diff
our $temp_dir_name;    # Name of temporary directory
our $cwd = getcwd();    # Current working directory
our $to_file;        # If set, indicates that output is written to a file
our $follow;        # If set, indicates that find shall follow links
our $diff_path = "";    # Path removed from tracefile when applying diff
our $base_directory;    # Base directory (cwd of gcc during compilation)
our $checksum;        # If set, calculate a checksum for each line
our $no_checksum;    # If set, don't calculate a checksum for each line
our $compat_libtool;    # If set, indicates that libtool mode is to be enabled
our $no_compat_libtool;    # If set, indicates that libtool mode is to be disabled
our $gcov_tool;
our @opt_ignore_errors;
our $initial;
our @include_patterns; # List of source file patterns to include
our @exclude_patterns; # List of source file patterns to exclude
our $no_recursion = 0;
our $to_package;
our $from_package;
our $maxdepth;
our $no_markers;
our $config;        # Configuration file contents
chomp($cwd);
our $tool_dir = dirname($0);    # Directory where genhtml tool is installed
our @temp_dirs;
our $gcov_gkv;        # gcov kernel support version found on machine
our $opt_derive_func_data;
our $opt_debug;
our $opt_list_full_path;
our $opt_no_list_full_path;
our $opt_list_width = 80;
our $opt_list_truncate_max = 20;
our $opt_external;
our $opt_no_external;
our $opt_config_file;
our %opt_rc;
our @opt_summary;
our $opt_compat;
our $ln_overall_found;
our $ln_overall_hit;
our $fn_overall_found;
our $fn_overall_hit;
our $br_overall_found;
our $br_overall_hit;
our $func_coverage = 1;
our $br_coverage = 1;


#
# Code entry point
#

$SIG{__WARN__} = \&warn_handler;
$SIG{__DIE__} = \&die_handler;
$SIG{'INT'} = \&abort_handler;
$SIG{'QUIT'} = \&abort_handler;

# Prettify version string
$lcov_version =~ s/\$\s*Revision\s*:?\s*(\S+)\s*\$/$1/;

# Add current working directory if $tool_dir is not already an absolute path
print ("tool_dir is $tool_dir\n");
if (!($tool_dir =~ /^\/(.*)$/) && !($tool_dir =~ /[a-zA-Z]:\\/) && !($tool_dir =~ /[a-zA-Z]:\//))
{
    $tool_dir = "$cwd/$tool_dir";
}

# Check command line for a configuration file name
Getopt::Long::Configure("pass_through", "no_auto_abbrev");
GetOptions("config-file=s" => \$opt_config_file,
       "rc=s%" => \%opt_rc);
Getopt::Long::Configure("default");

# Remove spaces around rc options
while (my ($key, $value) = each(%opt_rc)) {
    delete($opt_rc{$key});

    $key =~ s/^\s+|\s+$//g;
    $value =~ s/^\s+|\s+$//g;

    $opt_rc{$key} = $value;
}

# Read configuration file if available
if (defined($opt_config_file)) {
    $config = read_config($opt_config_file);
} elsif (defined($ENV{"HOME"}) && (-r $ENV{"HOME"}."/.lcovrc"))
{
    $config = read_config($ENV{"HOME"}."/.lcovrc");
}
elsif (-r "/etc/lcovrc")
{
    $config = read_config("/etc/lcovrc");
}

if ($config || %opt_rc)
{
    # Copy configuration file and --rc values to variables
    apply_config({
        "lcov_gcov_dir"        => \$gcov_dir,
        "lcov_tmp_dir"        => \$tmp_dir,
        "lcov_list_full_path"    => \$opt_list_full_path,
        "lcov_list_width"    => \$opt_list_width,
        "lcov_list_truncate_max"=> \$opt_list_truncate_max,
        "lcov_branch_coverage"    => \$br_coverage,
        "lcov_function_coverage"=> \$func_coverage,
    });
}

# Parse command line options
if (!GetOptions("directory|d|di=s" => \@directory,
        "add-tracefile|a=s" => \@add_tracefile,
        "list|l=s" => \$list,
        "kernel-directory|k=s" => \@kernel_directory,
        "extract|e=s" => \$extract,
        "remove|r=s" => \$remove,
        "diff=s" => \$diff,
        "convert-filenames" => \$convert_filenames,
        "strip=i" => \$strip,
        "capture|c" => \$capture,
        "output-file|o=s" => \$output_filename,
        "test-name|t=s" => \$test_name,
        "zerocounters|z" => \$reset,
        "quiet|q" => \$quiet,
        "help|h|?" => \$help,
        "version|v" => \$version,
        "follow|f" => \$follow,
        "path=s" => \$diff_path,
        "base-directory|b=s" => \$base_directory,
        "checksum" => \$checksum,
        "no-checksum" => \$no_checksum,
        "compat-libtool" => \$compat_libtool,
        "no-compat-libtool" => \$no_compat_libtool,
        "gcov-tool=s" => \$gcov_tool,
        "ignore-errors=s" => \@opt_ignore_errors,
        "initial|i" => \$initial,
		"include=s" => \@include_patterns,
		"exclude=s" => \@exclude_patterns,
        "no-recursion" => \$no_recursion,
        "to-package=s" => \$to_package,
        "from-package=s" => \$from_package,
        "no-markers" => \$no_markers,
        "derive-func-data" => \$opt_derive_func_data,
        "debug" => \$opt_debug,
        "list-full-path" => \$opt_list_full_path,
        "no-list-full-path" => \$opt_no_list_full_path,
        "external" => \$opt_external,
        "no-external" => \$opt_no_external,
        "summary=s" => \@opt_summary,
        "compat=s" => \$opt_compat,
        "config-file=s" => \$opt_config_file,
        "rc=s%" => \%opt_rc,
        ))
{
    print(STDERR "Use $tool_name --help to get usage information\n");
    exit(1);
}
else
{
    # Merge options
    if (defined($no_checksum))
    {
        $checksum = ($no_checksum ? 0 : 1);
        $no_checksum = undef;
    }

    if (defined($no_compat_libtool))
    {
        $compat_libtool = ($no_compat_libtool ? 0 : 1);
        $no_compat_libtool = undef;
    }

    if (defined($opt_no_list_full_path))
    {
        $opt_list_full_path = ($opt_no_list_full_path ? 0 : 1);
        $opt_no_list_full_path = undef;
    }

    if (defined($opt_no_external)) {
        $opt_external = 0;
        $opt_no_external = undef;
    }
}

# Check for help option
if ($help)
{
    print_usage(*STDOUT);
    exit(0);
}

# Check for version option
if ($version)
{
    print("$tool_name: $lcov_version\n");
    exit(0);
}

# Check list width option
if ($opt_list_width <= 40) {
    die("ERROR: lcov_list_width parameter out of range (needs to be ".
        "larger than 40)\n");
}

# Normalize --path text
$diff_path =~ s/\/$//;

if ($follow)
{
    $follow = "-follow";
}
else
{
    $follow = "";
}

if ($no_recursion)
{
    $maxdepth = "-maxdepth 1";
}
else
{
    $maxdepth = "";
}

# Check for valid options
check_options();

# Only --extract, --remove and --diff allow unnamed parameters
if (@ARGV && !($extract || $remove || $diff || @opt_summary))
{
    die("Extra parameter found: '".join(" ", @ARGV)."'\n".
        "Use $tool_name --help to get usage information\n");
}

# Check for output filename
$to_file = ($output_filename && ($output_filename ne "-"));

if ($capture)
{
    if (!$to_file)
    {
        # Option that tells geninfo to write to stdout
        $output_filename = "-";
    }
}

# Determine kernel directory for gcov data
if (!$from_package && !@directory && ($capture || $reset)) {
    ($gcov_gkv, $gcov_dir) = setup_gkv();
}

# Check for requested functionality
if ($reset)
{
    # Differentiate between user space and kernel reset
    if (@directory)
    {
        userspace_reset();
    }
    else
    {
        kernel_reset();
    }
}
elsif ($capture)
{
    # Capture source can be user space, kernel or package
    if ($from_package) {
        package_capture();
    } elsif (@directory) {
        userspace_capture();
    } else {
        if ($initial) {
            if (defined($to_package)) {
                die("ERROR: --initial cannot be used together ".
                    "with --to-package\n");
            }
            kernel_capture_initial();
        } else {
            kernel_capture();
        }
    }
}
elsif (@add_tracefile)
{
    ($ln_overall_found, $ln_overall_hit,
     $fn_overall_found, $fn_overall_hit,
     $br_overall_found, $br_overall_hit) = add_traces();
}
elsif ($remove)
{
    ($ln_overall_found, $ln_overall_hit,
     $fn_overall_found, $fn_overall_hit,
     $br_overall_found, $br_overall_hit) = remove();
}
elsif ($extract)
{
    ($ln_overall_found, $ln_overall_hit,
     $fn_overall_found, $fn_overall_hit,
     $br_overall_found, $br_overall_hit) = extract();
}
elsif ($list)
{
    list();
}
elsif ($diff)
{
    if (scalar(@ARGV) != 1)
    {
        die("ERROR: option --diff requires one additional argument!\n".
            "Use $tool_name --help to get usage information\n");
    }
    ($ln_overall_found, $ln_overall_hit,
     $fn_overall_found, $fn_overall_hit,
     $br_overall_found, $br_overall_hit) = diff();
}
elsif (@opt_summary)
{
    ($ln_overall_found, $ln_overall_hit,
     $fn_overall_found, $fn_overall_hit,
     $br_overall_found, $br_overall_hit) = summary();
}

temp_cleanup();

if (defined($ln_overall_found)) {
    print_overall_rate(1, $ln_overall_found, $ln_overall_hit,
               1, $fn_overall_found, $fn_overall_hit,
               1, $br_overall_found, $br_overall_hit);
} else {
    info("Done.\n") if (!$list && !$capture);
}
exit(0);

#
# print_usage(handle)
#
# Print usage information.
#

sub print_usage(*)
{
    local *HANDLE = $_[0];

    print(HANDLE <<END_OF_USAGE);
Usage: $tool_name [OPTIONS]

Use lcov to collect coverage data from either the currently running Linux
kernel or from a user space application. Specify the --directory option to
get coverage data for a user space program.

Misc:
  -h, --help                      Print this help, then exit
  -v, --version                   Print version number, then exit
  -q, --quiet                     Do not print progress messages

Operation:
  -z, --zerocounters              Reset all execution counts to zero
  -c, --capture                   Capture coverage data
  -a, --add-tracefile FILE        Add contents of tracefiles
  -e, --extract FILE PATTERN      Extract files matching PATTERN from FILE
  -r, --remove FILE PATTERN       Remove files matching PATTERN from FILE
  -l, --list FILE                 List contents of tracefile FILE
      --diff FILE DIFF            Transform tracefile FILE according to DIFF
      --summary FILE              Show summary coverage data for tracefiles

Options:
  -i, --initial                   Capture initial zero coverage data
  -t, --test-name NAME            Specify test name to be stored with data
  -o, --output-file FILENAME      Write data to FILENAME instead of stdout
  -d, --directory DIR             Use .da files in DIR instead of kernel
  -f, --follow                    Follow links when searching .da files
  -k, --kernel-directory KDIR     Capture kernel coverage data only from KDIR
  -b, --base-directory DIR        Use DIR as base directory for relative paths
      --convert-filenames         Convert filenames when applying diff
      --strip DEPTH               Strip initial DEPTH directory levels in diff
      --path PATH                 Strip PATH from tracefile when applying diff
      --(no-)checksum             Enable (disable) line checksumming
      --(no-)compat-libtool       Enable (disable) libtool compatibility mode
      --gcov-tool TOOL            Specify gcov tool location
      --ignore-errors ERRORS      Continue after ERRORS (gcov, source, graph)
      --no-recursion              Exclude subdirectories from processing
      --to-package FILENAME       Store unprocessed coverage data in FILENAME
      --from-package FILENAME     Capture from unprocessed data in FILENAME
      --no-markers                Ignore exclusion markers in source code
      --derive-func-data          Generate function data from line data
      --list-full-path            Print full path during a list operation
      --(no-)external             Include (ignore) data for external files
      --config-file FILENAME      Specify configuration file location
      --rc SETTING=VALUE          Override configuration file setting
      --compat MODE=on|off|auto   Set compat MODE (libtool, hammer, split_crc)

For more information see: $lcov_url
END_OF_USAGE
    ;
}


#
# check_options()
#
# Check for valid combination of command line options. Die on error.
#

sub check_options()
{
    my $i = 0;

    # Count occurrence of mutually exclusive options
    $reset && $i++;
    $capture && $i++;
    @add_tracefile && $i++;
    $extract && $i++;
    $remove && $i++;
    $list && $i++;
    $diff && $i++;
    @opt_summary && $i++;
    
    if ($i == 0)
    {
        die("Need one of options -z, -c, -a, -e, -r, -l, ".
            "--diff or --summary\n".
            "Use $tool_name --help to get usage information\n");
    }
    elsif ($i > 1)
    {
        die("ERROR: only one of -z, -c, -a, -e, -r, -l, ".
            "--diff or --summary allowed!\n".
            "Use $tool_name --help to get usage information\n");
    }
}


#
# userspace_reset()
#
# Reset coverage data found in DIRECTORY by deleting all contained .da files.
#
# Die on error.
#

sub userspace_reset()
{
    my $current_dir;
    my @file_list;

    foreach $current_dir (@directory)
    {
        info("Deleting all .da files in $current_dir".
             ($no_recursion?"\n":" and subdirectories\n"));
        @file_list = `find "$current_dir" $maxdepth $follow -name \\*\\.da -o -name \\*\\.gcda -type f 2>/dev/null`;
        chomp(@file_list);
        foreach (@file_list)
        {
            unlink($_) or die("ERROR: cannot remove file $_!\n");
        }
    }
}


#
# userspace_capture()
#
# Capture coverage data found in DIRECTORY and write it to a package (if
# TO_PACKAGE specified) or to OUTPUT_FILENAME or STDOUT.
#
# Die on error.
#

sub userspace_capture()
{
    my $dir;
    my $build;

    if (!defined($to_package)) {
        lcov_geninfo(@directory);
        return;
    }
    if (scalar(@directory) != 1) {
        die("ERROR: -d may be specified only once with --to-package\n");
    }
    $dir = $directory[0];
    if (defined($base_directory)) {
        $build = $base_directory;
    } else {
        $build = $dir;
    }
    create_package($to_package, $dir, $build);
}


#
# kernel_reset()
#
# Reset kernel coverage.
#
# Die on error.
#

sub kernel_reset()
{
    local *HANDLE;
    my $reset_file;

    info("Resetting kernel execution counters\n");
    if (-e "$gcov_dir/vmlinux") {
        $reset_file = "$gcov_dir/vmlinux";
    } elsif (-e "$gcov_dir/reset") {
        $reset_file = "$gcov_dir/reset";
    } else {
        die("ERROR: no reset control found in $gcov_dir\n");
    }
    open(HANDLE, ">", $reset_file) or
        die("ERROR: cannot write to $reset_file!\n");
    print(HANDLE "0");
    close(HANDLE);
}


#
# lcov_copy_single(from, to)
# 
# Copy single regular file FROM to TO without checking its size. This is
# required to work with special files generated by the kernel
# seq_file-interface.
#
#
sub lcov_copy_single($$)
{
    my ($from, $to) = @_;
    my $content;
    local $/;
    local *HANDLE;

    open(HANDLE, "<", $from) or die("ERROR: cannot read $from: $!\n");
    $content = <HANDLE>;
    close(HANDLE);
    open(HANDLE, ">", $to) or die("ERROR: cannot write $from: $!\n");
    if (defined($content)) {
        print(HANDLE $content);
    }
    close(HANDLE);
}

#
# lcov_find(dir, function, data[, extension, ...)])
#
# Search DIR for files and directories whose name matches PATTERN and run
# FUNCTION for each match. If not pattern is specified, match all names.
#
# FUNCTION has the following prototype:
#   function(dir, relative_name, data)
#
# Where:
#   dir: the base directory for this search
#   relative_name: the name relative to the base directory of this entry
#   data: the DATA variable passed to lcov_find
#
sub lcov_find($$$;@)
{
    my ($dir, $fn, $data, @pattern) = @_;
    my $result;
    my $_fn = sub {
        my $filename = $File::Find::name;

        if (defined($result)) {
            return;
        }        
        $filename = abs2rel($filename, $dir);
        foreach (@pattern) {
            if ($filename =~ /$_/) {
                goto ok;
            }
        }
        return;
    ok:
        $result = &$fn($dir, $filename, $data);
    };
    if (scalar(@pattern) == 0) {
        @pattern = ".*";
    }
    find( { wanted => $_fn, no_chdir => 1 }, $dir);

    return $result;
}

#
# lcov_copy_fn(from, rel, to)
#
# Copy directories, files and links from/rel to to/rel.
#

sub lcov_copy_fn($$$)
{
    my ($from, $rel, $to) = @_;
    my $absfrom = canonpath(catfile($from, $rel));
    my $absto = canonpath(catfile($to, $rel));

    if (-d) {
        if (! -d $absto) {
            mkpath($absto) or
                die("ERROR: cannot create directory $absto\n");
            chmod(0700, $absto);
        }
    } elsif (-l) {
        # Copy symbolic link
        my $link = readlink($absfrom);

        if (!defined($link)) {
            die("ERROR: cannot read link $absfrom: $!\n");
        }
        symlink($link, $absto) or
            die("ERROR: cannot create link $absto: $!\n");
    } else {
        lcov_copy_single($absfrom, $absto);
        chmod(0600, $absto);
    }
    return undef;
}

#
# lcov_copy(from, to, subdirs)
# 
# Copy all specified SUBDIRS and files from directory FROM to directory TO. For
# regular files, copy file contents without checking its size. This is required
# to work with seq_file-generated files.
#

sub lcov_copy($$;@)
{
    my ($from, $to, @subdirs) = @_;
    my @pattern;

    foreach (@subdirs) {
        push(@pattern, "^$_");
    }
    lcov_find($from, \&lcov_copy_fn, $to, @pattern);
}

#
# lcov_geninfo(directory)
#
# Call geninfo for the specified directory and with the parameters specified
# at the command line.
#

sub lcov_geninfo(@)
{
    my (@dir) = @_;
    my @param;

    # Capture data
    info("Capturing coverage data from ".join(" ", @dir)."\n");
    # FR changed path from "$tool_dir/geninfo"
    @param = ("$tool_dir//geninfo.perl", @dir);

    print("param are:\n");
    foreach (@param)
    {
        print ("+$_\n");
    }

    if ($output_filename)
    {
        @param = (@param, "--output-filename", $output_filename);
    }
    if ($test_name)
    {
        @param = (@param, "--test-name", $test_name);
    }
    if ($follow)
    {
        @param = (@param, "--follow");
    }
    if ($quiet)
    {
        @param = (@param, "--quiet");
    }
    if (defined($checksum))
    {
        if ($checksum)
        {
            @param = (@param, "--checksum");
        }
        else
        {
            @param = (@param, "--no-checksum");
        }
    }
    if ($base_directory)
    {
        @param = (@param, "--base-directory", $base_directory);
    }
    if ($no_compat_libtool)
    {
        @param = (@param, "--no-compat-libtool");
    }
    elsif ($compat_libtool)
    {
        @param = (@param, "--compat-libtool");
    }
    if ($gcov_tool)
    {
        @param = (@param, "--gcov-tool", $gcov_tool);
    }
    foreach (@opt_ignore_errors) {
        @param = (@param, "--ignore-errors", $_);
    }
    if ($no_recursion) {
        @param = (@param, "--no-recursion");
    }
    if ($initial)
    {
        @param = (@param, "--initial");
    }
    if ($no_markers)
    {
        @param = (@param, "--no-markers");
    }
    if ($opt_derive_func_data)
    {
        @param = (@param, "--derive-func-data");
    }
    if ($opt_debug)
    {
        @param = (@param, "--debug");
    }
    if (defined($opt_external) && $opt_external)
    {
        @param = (@param, "--external");
    }
    if (defined($opt_external) && !$opt_external)
    {
        @param = (@param, "--no-external");
    }
    if (defined($opt_compat)) {
        @param = (@param, "--compat", $opt_compat);
    }
    if (%opt_rc) {
        foreach my $key (keys(%opt_rc)) {
            @param = (@param, "--rc", "$key=".$opt_rc{$key});
        }
    }
    if (defined($opt_config_file)) {
        @param = (@param, "--config-file", $opt_config_file);
    }

	foreach (@include_patterns) {
		@param = (@param, "--include", $_);
	}
	foreach (@exclude_patterns) {
		@param = (@param, "--exclude", $_);
	}

    my $Command = join(' ', $perl_exe, @param);

    print "Command is: $Command \n";
	system($Command) and exit($? >> 8);
}

#
# read_file(filename)
#
# Return the contents of the file defined by filename.
#

sub read_file($)
{
    my ($filename) = @_;
    my $content;
    local $\;
    local *HANDLE;

    open(HANDLE, "<", $filename) || return undef;
    $content = <HANDLE>;
    close(HANDLE);

    return $content;
}

#
# get_package(package_file)
#
# Unpack unprocessed coverage data files from package_file to a temporary
# directory and return directory name, build directory and gcov kernel version
# as found in package.
#

sub get_package($)
{
    my ($file) = @_;
    my $dir = create_temp_dir();
    my $gkv;
    my $build;
    my $cwd = getcwd();
    my $count;
    local *HANDLE;

    info("Reading package $file:\n");
    info("  data directory .......: $dir\n");
    $file = abs_path($file);
    chdir($dir);
    open(HANDLE, "-|", "tar xvfz '$file' 2>/dev/null")
        or die("ERROR: could not process package $file\n");
    while (<HANDLE>) {
        if (/\.da$/ || /\.gcda$/) {
            $count++;
        }
    }
    close(HANDLE);
    $build = read_file("$dir/$pkg_build_file");
    if (defined($build)) {
        info("  build directory ......: $build\n");
    }
    $gkv = read_file("$dir/$pkg_gkv_file");
    if (defined($gkv)) {
        $gkv = int($gkv);
        if ($gkv != $GKV_PROC && $gkv != $GKV_SYS) {
            die("ERROR: unsupported gcov kernel version found ".
                "($gkv)\n");
        }
        info("  content type .........: kernel data\n");
        info("  gcov kernel version ..: %s\n", $GKV_NAME[$gkv]);
    } else {
        info("  content type .........: application data\n");
    }
    info("  data files ...........: $count\n");
    chdir($cwd);

    return ($dir, $build, $gkv);
}

#
# write_file(filename, $content)
#
# Create a file named filename and write the specified content to it.
#

sub write_file($$)
{
    my ($filename, $content) = @_;
    local *HANDLE;

    open(HANDLE, ">", $filename) || return 0;
    print(HANDLE $content);
    close(HANDLE) || return 0;

    return 1;
}

# count_package_data(filename)
#
# Count the number of coverage data files in the specified package file.
#

sub count_package_data($)
{
    my ($filename) = @_;
    local *HANDLE;
    my $count = 0;

    open(HANDLE, "-|", "tar tfz '$filename'") or return undef;
    while (<HANDLE>) {
        if (/\.da$/ || /\.gcda$/) {
            $count++;
        }
    }
    close(HANDLE);
    return $count;
}

#
# create_package(package_file, source_directory, build_directory[,
#          kernel_gcov_version])
#
# Store unprocessed coverage data files from source_directory to package_file.
#

sub create_package($$$;$)
{
    my ($file, $dir, $build, $gkv) = @_;
    my $cwd = getcwd();

    # Print information about the package
    info("Creating package $file:\n");
    info("  data directory .......: $dir\n");

    # Handle build directory
    if (defined($build)) {
        info("  build directory ......: $build\n");
        write_file("$dir/$pkg_build_file", $build)
            or die("ERROR: could not write to ".
                   "$dir/$pkg_build_file\n");
    }

    # Handle gcov kernel version data
    if (defined($gkv)) {
        info("  content type .........: kernel data\n");
        info("  gcov kernel version ..: %s\n", $GKV_NAME[$gkv]);
        write_file("$dir/$pkg_gkv_file", $gkv)
            or die("ERROR: could not write to ".
                   "$dir/$pkg_gkv_file\n");
    } else {
        info("  content type .........: application data\n");
    }

    # Create package
    $file = abs_path($file);
    chdir($dir);
    system("tar cfz $file .")
        and die("ERROR: could not create package $file\n");

    # Remove temporary files
    unlink("$dir/$pkg_build_file");
    unlink("$dir/$pkg_gkv_file");

    # Show number of data files
    if (!$quiet) {
        my $count = count_package_data($file);

        if (defined($count)) {
            info("  data files ...........: $count\n");
        }
    }
    chdir($cwd);
}

sub find_link_fn($$$)
{
    my ($from, $rel, $filename) = @_;
    my $absfile = catfile($from, $rel, $filename);

    if (-l $absfile) {
        return $absfile;
    }
    return undef;
}

#
# get_base(dir)
#
# Return (BASE, OBJ), where
#  - BASE: is the path to the kernel base directory relative to dir
#  - OBJ: is the absolute path to the kernel build directory
#

sub get_base($)
{
    my ($dir) = @_;
    my $marker = "kernel/gcov/base.gcno";
    my $markerfile;
    my $sys;
    my $obj;
    my $link;

    $markerfile = lcov_find($dir, \&find_link_fn, $marker);
    if (!defined($markerfile)) {
        return (undef, undef);
    }

    # sys base is parent of parent of markerfile.
    $sys = abs2rel(dirname(dirname(dirname($markerfile))), $dir);

    # obj base is parent of parent of markerfile link target.
    $link = readlink($markerfile);
    if (!defined($link)) {
        die("ERROR: could not read $markerfile\n");
    }
    $obj = dirname(dirname(dirname($link)));

    return ($sys, $obj);
}

#
# apply_base_dir(data_dir, base_dir, build_dir, @directories)
#
# Make entries in @directories relative to data_dir.
#

sub apply_base_dir($$$@)
{
    my ($data, $base, $build, @dirs) = @_;
    my $dir;
    my @result;

    foreach $dir (@dirs) {
        # Is directory path relative to data directory?
        if (-d catdir($data, $dir)) {
            push(@result, $dir);
            next;
        }
        # Relative to the auto-detected base-directory?
        if (defined($base)) {
            if (-d catdir($data, $base, $dir)) {
                push(@result, catdir($base, $dir));
                next;
            }
        }
        # Relative to the specified base-directory?
        if (defined($base_directory)) {
            if (file_name_is_absolute($base_directory)) {
                $base = abs2rel($base_directory, rootdir());
            } else {
                $base = $base_directory;
            }
            if (-d catdir($data, $base, $dir)) {
                push(@result, catdir($base, $dir));
                next;
            }
        }
        # Relative to the build directory?
        if (defined($build)) {
            if (file_name_is_absolute($build)) {
                $base = abs2rel($build, rootdir());
            } else {
                $base = $build;
            }
            if (-d catdir($data, $base, $dir)) {
                push(@result, catdir($base, $dir));
                next;
            }
        }
        die("ERROR: subdirectory $dir not found\n".
            "Please use -b to specify the correct directory\n");
    }
    return @result;
}

#
# copy_gcov_dir(dir, [@subdirectories])
#
# Create a temporary directory and copy all or, if specified, only some
# subdirectories from dir to that directory. Return the name of the temporary
# directory.
#

sub copy_gcov_dir($;@)
{
    my ($data, @dirs) = @_;
    my $tempdir = create_temp_dir();

    info("Copying data to temporary directory $tempdir\n");
    lcov_copy($data, $tempdir, @dirs);

    return $tempdir;
}

#
# kernel_capture_initial
#
# Capture initial kernel coverage data, i.e. create a coverage data file from
# static graph files which contains zero coverage data for all instrumented
# lines.
#

sub kernel_capture_initial()
{
    my $build;
    my $source;
    my @params;

    if (defined($base_directory)) {
        $build = $base_directory;
        $source = "specified";
    } else {
        (undef, $build) = get_base($gcov_dir);
        if (!defined($build)) {
            die("ERROR: could not auto-detect build directory.\n".
                "Please use -b to specify the build directory\n");
        }
        $source = "auto-detected";
    }
    info("Using $build as kernel build directory ($source)\n");
    # Build directory needs to be passed to geninfo
    $base_directory = $build;
    if (@kernel_directory) {
        foreach my $dir (@kernel_directory) {
            push(@params, "$build/$dir");
        }
    } else {
        push(@params, $build);
    }
    lcov_geninfo(@params);
}

#
# kernel_capture_from_dir(directory, gcov_kernel_version, build)
#
# Perform the actual kernel coverage capturing from the specified directory
# assuming that the data was copied from the specified gcov kernel version.
#

sub kernel_capture_from_dir($$$)
{
    my ($dir, $gkv, $build) = @_;

    # Create package or coverage file
    if (defined($to_package)) {
        create_package($to_package, $dir, $build, $gkv);
    } else {
        # Build directory needs to be passed to geninfo
        $base_directory = $build;
        lcov_geninfo($dir);
    }
}

#
# adjust_kernel_dir(dir, build)
#
# Adjust directories specified with -k so that they point to the directory
# relative to DIR. Return the build directory if specified or the auto-
# detected build-directory.
#

sub adjust_kernel_dir($$)
{
    my ($dir, $build) = @_;
    my ($sys_base, $build_auto) = get_base($dir);

    if (!defined($build)) {
        $build = $build_auto;
    }
    if (!defined($build)) {
        die("ERROR: could not auto-detect build directory.\n".
            "Please use -b to specify the build directory\n");
    }
    # Make @kernel_directory relative to sysfs base
    if (@kernel_directory) {
        @kernel_directory = apply_base_dir($dir, $sys_base, $build,
                           @kernel_directory);
    }
    return $build;
}

sub kernel_capture()
{
    my $data_dir;
    my $build = $base_directory;

    if ($gcov_gkv == $GKV_SYS) {
        $build = adjust_kernel_dir($gcov_dir, $build);
    }
    $data_dir = copy_gcov_dir($gcov_dir, @kernel_directory);
    kernel_capture_from_dir($data_dir, $gcov_gkv, $build);
}

#
# package_capture()
#
# Capture coverage data from a package of unprocessed coverage data files
# as generated by lcov --to-package.
#

sub package_capture()
{
    my $dir;
    my $build;
    my $gkv;

    ($dir, $build, $gkv) = get_package($from_package);

    # Check for build directory
    if (defined($base_directory)) {
        if (defined($build)) {
            info("Using build directory specified by -b.\n");
        }
        $build = $base_directory;
    }

    # Do the actual capture
    if (defined($gkv)) {
        if ($gkv == $GKV_SYS) {
            $build = adjust_kernel_dir($dir, $build);
        }
        if (@kernel_directory) {
            $dir = copy_gcov_dir($dir, @kernel_directory);    
        }
        kernel_capture_from_dir($dir, $gkv, $build);
    } else {
        # Build directory needs to be passed to geninfo
        $base_directory = $build;
        lcov_geninfo($dir);
    }
}


#
# info(printf_parameter)
#
# Use printf to write PRINTF_PARAMETER to stdout only when the $quiet flag
# is not set.
#

sub info(@)
{
    if (!$quiet)
    {
        # Print info string
        if ($to_file)
        {
            printf(@_)
        }
        else
        {
            # Don't interfere with the .info output to STDOUT
            printf(STDERR @_);
        }
    }
}


#
# create_temp_dir()
#
# Create a temporary directory and return its path.
#
# Die on error.
#

sub create_temp_dir()
{
    my $dir;

    if (defined($tmp_dir)) {
        $dir = tempdir(DIR => $tmp_dir, CLEANUP => 1);
    } else {
        $dir = tempdir(CLEANUP => 1);
    }
    if (!defined($dir)) {
        die("ERROR: cannot create temporary directory\n");
    }
    push(@temp_dirs, $dir);

    return $dir;
}


#
# br_taken_to_num(taken)
#
# Convert a branch taken value .info format to number format.
#

sub br_taken_to_num($)
{
    my ($taken) = @_;

    return 0 if ($taken eq '-');
    return $taken + 1;
}


#
# br_num_to_taken(taken)
#
# Convert a branch taken value in number format to .info format.
#

sub br_num_to_taken($)
{
    my ($taken) = @_;

    return '-' if ($taken == 0);
    return $taken - 1;
}


#
# br_taken_add(taken1, taken2)
#
# Return the result of taken1 + taken2 for 'branch taken' values.
#

sub br_taken_add($$)
{
    my ($t1, $t2) = @_;

    return $t1 if (!defined($t2));
    return $t2 if (!defined($t1));
    return $t1 if ($t2 eq '-');
    return $t2 if ($t1 eq '-');
    return $t1 + $t2;
}


#
# br_taken_sub(taken1, taken2)
#
# Return the result of taken1 - taken2 for 'branch taken' values. Return 0
# if the result would become negative.
#

sub br_taken_sub($$)
{
    my ($t1, $t2) = @_;

    return $t1 if (!defined($t2));
    return undef if (!defined($t1));
    return $t1 if ($t1 eq '-');
    return $t1 if ($t2 eq '-');
    return 0 if $t2 > $t1;
    return $t1 - $t2;
}


#
#
# br_ivec_len(vector)
#
# Return the number of entries in the branch coverage vector.
#

sub br_ivec_len($)
{
    my ($vec) = @_;

    return 0 if (!defined($vec));
    return (length($vec) * 8 / $BR_VEC_WIDTH) / $BR_VEC_ENTRIES;
}


#
# br_ivec_push(vector, block, branch, taken)
#
# Add an entry to the branch coverage vector. If an entry with the same
# branch ID already exists, add the corresponding taken values.
#

sub br_ivec_push($$$$)
{
    my ($vec, $block, $branch, $taken) = @_;
    my $offset;
    my $num = br_ivec_len($vec);
    my $i;

    $vec = "" if (!defined($vec));
    $block = $BR_VEC_MAX if $block < 0;

    # Check if branch already exists in vector
    for ($i = 0; $i < $num; $i++) {
        my ($v_block, $v_branch, $v_taken) = br_ivec_get($vec, $i);
        $v_block = $BR_VEC_MAX if $v_block < 0;

        next if ($v_block != $block || $v_branch != $branch);

        # Add taken counts
        $taken = br_taken_add($taken, $v_taken);
        last;
    }

    $offset = $i * $BR_VEC_ENTRIES;
    $taken = br_taken_to_num($taken);

    # Add to vector
    vec($vec, $offset + $BR_BLOCK, $BR_VEC_WIDTH) = $block;
    vec($vec, $offset + $BR_BRANCH, $BR_VEC_WIDTH) = $branch;
    vec($vec, $offset + $BR_TAKEN, $BR_VEC_WIDTH) = $taken;

    return $vec;
}


#
# br_ivec_get(vector, number)
#
# Return an entry from the branch coverage vector.
#

sub br_ivec_get($$)
{
    my ($vec, $num) = @_;
    my $block;
    my $branch;
    my $taken;
    my $offset = $num * $BR_VEC_ENTRIES;

    # Retrieve data from vector
    $block    = vec($vec, $offset + $BR_BLOCK, $BR_VEC_WIDTH);
    $block = -1 if ($block == $BR_VEC_MAX);
    $branch = vec($vec, $offset + $BR_BRANCH, $BR_VEC_WIDTH);
    $taken    = vec($vec, $offset + $BR_TAKEN, $BR_VEC_WIDTH);

    # Decode taken value from an integer
    $taken = br_num_to_taken($taken);

    return ($block, $branch, $taken);
}


#
# get_br_found_and_hit(brcount)
#
# Return (br_found, br_hit) for brcount
#

sub get_br_found_and_hit($)
{
    my ($brcount) = @_;
    my $line;
    my $br_found = 0;
    my $br_hit = 0;

    foreach $line (keys(%{$brcount})) {
        my $brdata = $brcount->{$line};
        my $i;
        my $num = br_ivec_len($brdata);

        for ($i = 0; $i < $num; $i++) {
            my $taken;

            (undef, undef, $taken) = br_ivec_get($brdata, $i);

            $br_found++;
            $br_hit++ if ($taken ne "-" && $taken > 0);
        }
    }

    return ($br_found, $br_hit);
}


#
# read_info_file(info_filename)
#
# Read in the contents of the .info file specified by INFO_FILENAME. Data will
# be returned as a reference to a hash containing the following mappings:
#
# %result: for each filename found in file -> \%data
#
# %data: "test"  -> \%testdata
#        "sum"   -> \%sumcount
#        "func"  -> \%funcdata
#        "found" -> $lines_found (number of instrumented lines found in file)
#     "hit"   -> $lines_hit (number of executed lines in file)
#        "f_found" -> $fn_found (number of instrumented functions found in file)
#     "f_hit"   -> $fn_hit (number of executed functions in file)
#        "b_found" -> $br_found (number of instrumented branches found in file)
#     "b_hit"   -> $br_hit (number of executed branches in file)
#        "check" -> \%checkdata
#        "testfnc" -> \%testfncdata
#        "sumfnc"  -> \%sumfnccount
#        "testbr"  -> \%testbrdata
#        "sumbr"   -> \%sumbrcount
#
# %testdata   : name of test affecting this file -> \%testcount
# %testfncdata: name of test affecting this file -> \%testfnccount
# %testbrdata:  name of test affecting this file -> \%testbrcount
#
# %testcount   : line number   -> execution count for a single test
# %testfnccount: function name -> execution count for a single test
# %testbrcount : line number   -> branch coverage data for a single test
# %sumcount    : line number   -> execution count for all tests
# %sumfnccount : function name -> execution count for all tests
# %sumbrcount  : line number   -> branch coverage data for all tests
# %funcdata    : function name -> line number
# %checkdata   : line number   -> checksum of source code line
# $brdata      : vector of items: block, branch, taken
# 
# Note that .info file sections referring to the same file and test name
# will automatically be combined by adding all execution counts.
#
# Note that if INFO_FILENAME ends with ".gz", it is assumed that the file
# is compressed using GZIP. If available, GUNZIP will be used to decompress
# this file.
#
# Die on error.
#

sub read_info_file($)
{
    my $tracefile = $_[0];        # Name of tracefile
    my %result;            # Resulting hash: file -> data
    my $data;            # Data handle for current entry
    my $testdata;            #       "             "
    my $testcount;            #       "             "
    my $sumcount;            #       "             "
    my $funcdata;            #       "             "
    my $checkdata;            #       "             "
    my $testfncdata;
    my $testfnccount;
    my $sumfnccount;
    my $testbrdata;
    my $testbrcount;
    my $sumbrcount;
    my $line;            # Current line read from .info file
    my $testname;            # Current test name
    my $filename;            # Current filename
    my $hitcount;            # Count for lines hit
    my $count;            # Execution count of current line
    my $negative;            # If set, warn about negative counts
    my $changed_testname;        # If set, warn about changed testname
    my $line_checksum;        # Checksum of current line
    local *INFO_HANDLE;        # Filehandle for .info file

    info("Reading tracefile $tracefile\n");

    # Check if file exists and is readable
    stat($_[0]);
    if (!(-r _))
    {
        die("ERROR: cannot read file $_[0]!\n");
    }

    # Check if this is really a plain file
    if (!(-f _))
    {
        die("ERROR: not a plain file: $_[0]!\n");
    }

    # Check for .gz extension
    if ($_[0] =~ /\.gz$/)
    {
        # Check for availability of GZIP tool
        system_no_output(1, "gunzip" ,"-h")
            and die("ERROR: gunzip command not available!\n");

        # Check integrity of compressed file
        system_no_output(1, "gunzip", "-t", $_[0])
            and die("ERROR: integrity check failed for ".
                "compressed file $_[0]!\n");

        # Open compressed file
        open(INFO_HANDLE, "-|", "gunzip -c '$_[0]'")
            or die("ERROR: cannot start gunzip to decompress ".
                   "file $_[0]!\n");
    }
    else
    {
        # Open decompressed file
        open(INFO_HANDLE, "<", $_[0])
            or die("ERROR: cannot read file $_[0]!\n");
    }

    $testname = "";
    while (<INFO_HANDLE>)
    {
        chomp($_);
        $line = $_;

        # Switch statement
        foreach ($line)
        {
            /^TN:([^,]*)(,diff)?/ && do
            {
                # Test name information found
                $testname = defined($1) ? $1 : "";
                if ($testname =~ s/\W/_/g)
                {
                    $changed_testname = 1;
                }
                $testname .= $2 if (defined($2));
                last;
            };

            /^[SK]F:(.*)/ && do
            {
                # Filename information found
                # Retrieve data for new entry
                $filename = $1;

                $data = $result{$filename};
                ($testdata, $sumcount, $funcdata, $checkdata,
                 $testfncdata, $sumfnccount, $testbrdata,
                 $sumbrcount) =
                    get_info_entry($data);

                if (defined($testname))
                {
                    $testcount = $testdata->{$testname};
                    $testfnccount = $testfncdata->{$testname};
                    $testbrcount = $testbrdata->{$testname};
                }
                else
                {
                    $testcount = {};
                    $testfnccount = {};
                    $testbrcount = {};
                }
                last;
            };

            /^DA:(\d+),(-?\d+)(,[^,\s]+)?/ && do
            {
                # Fix negative counts
                $count = $2 < 0 ? 0 : $2;
                if ($2 < 0)
                {
                    $negative = 1;
                }
                # Execution count found, add to structure
                # Add summary counts
                $sumcount->{$1} += $count;

                # Add test-specific counts
                if (defined($testname))
                {
                    $testcount->{$1} += $count;
                }

                # Store line checksum if available
                if (defined($3))
                {
                    $line_checksum = substr($3, 1);

                    # Does it match a previous definition
                    if (defined($checkdata->{$1}) &&
                        ($checkdata->{$1} ne
                         $line_checksum))
                    {
                        die("ERROR: checksum mismatch ".
                            "at $filename:$1\n");
                    }

                    $checkdata->{$1} = $line_checksum;
                }
                last;
            };

            /^FN:(\d+),([^,]+)/ && do
            {
                last if (!$func_coverage);

                # Function data found, add to structure
                $funcdata->{$2} = $1;

                # Also initialize function call data
                if (!defined($sumfnccount->{$2})) {
                    $sumfnccount->{$2} = 0;
                }
                if (defined($testname))
                {
                    if (!defined($testfnccount->{$2})) {
                        $testfnccount->{$2} = 0;
                    }
                }
                last;
            };

            /^FNDA:(\d+),([^,]+)/ && do
            {
                last if (!$func_coverage);

                # Function call count found, add to structure
                # Add summary counts
                $sumfnccount->{$2} += $1;

                # Add test-specific counts
                if (defined($testname))
                {
                    $testfnccount->{$2} += $1;
                }
                last;
            };

            /^BRDA:(\d+),(\d+),(\d+),(\d+|-)/ && do {
                # Branch coverage data found
                my ($line, $block, $branch, $taken) =
                   ($1, $2, $3, $4);

                last if (!$br_coverage);
                $sumbrcount->{$line} =
                    br_ivec_push($sumbrcount->{$line},
                             $block, $branch, $taken);

                # Add test-specific counts
                if (defined($testname)) {
                    $testbrcount->{$line} =
                        br_ivec_push(
                            $testbrcount->{$line},
                            $block, $branch,
                            $taken);
                }
                last;
            };

            /^end_of_record/ && do
            {
                # Found end of section marker
                if ($filename)
                {
                    # Store current section data
                    if (defined($testname))
                    {
                        $testdata->{$testname} =
                            $testcount;
                        $testfncdata->{$testname} =
                            $testfnccount;
                        $testbrdata->{$testname} =
                            $testbrcount;
                    }    

                    set_info_entry($data, $testdata,
                               $sumcount, $funcdata,
                               $checkdata, $testfncdata,
                               $sumfnccount,
                               $testbrdata,
                               $sumbrcount);
                    $result{$filename} = $data;
                    last;
                }
            };

            # default
            last;
        }
    }
    close(INFO_HANDLE);

    # Calculate hit and found values for lines and functions of each file
    foreach $filename (keys(%result))
    {
        $data = $result{$filename};

        ($testdata, $sumcount, undef, undef, $testfncdata,
         $sumfnccount, $testbrdata, $sumbrcount) =
            get_info_entry($data);

        # Filter out empty files
        if (scalar(keys(%{$sumcount})) == 0)
        {
            delete($result{$filename});
            next;
        }
        # Filter out empty test cases
        foreach $testname (keys(%{$testdata}))
        {
            if (!defined($testdata->{$testname}) ||
                scalar(keys(%{$testdata->{$testname}})) == 0)
            {
                delete($testdata->{$testname});
                delete($testfncdata->{$testname});
            }
        }

        $data->{"found"} = scalar(keys(%{$sumcount}));
        $hitcount = 0;

        foreach (keys(%{$sumcount}))
        {
            if ($sumcount->{$_} > 0) { $hitcount++; }
        }

        $data->{"hit"} = $hitcount;

        # Get found/hit values for function call data
        $data->{"f_found"} = scalar(keys(%{$sumfnccount}));
        $hitcount = 0;

        foreach (keys(%{$sumfnccount})) {
            if ($sumfnccount->{$_} > 0) {
                $hitcount++;
            }
        }
        $data->{"f_hit"} = $hitcount;

        # Get found/hit values for branch data
        {
            my ($br_found, $br_hit) = get_br_found_and_hit($sumbrcount);

            $data->{"b_found"} = $br_found;
            $data->{"b_hit"} = $br_hit;
        }
    }

    if (scalar(keys(%result)) == 0)
    {
        die("ERROR: no valid records found in tracefile $tracefile\n");
    }
    if ($negative)
    {
        warn("WARNING: negative counts found in tracefile ".
             "$tracefile\n");
    }
    if ($changed_testname)
    {
        warn("WARNING: invalid characters removed from testname in ".
             "tracefile $tracefile\n");
    }

    return(\%result);
}


#
# get_info_entry(hash_ref)
#
# Retrieve data from an entry of the structure generated by read_info_file().
# Return a list of references to hashes:
# (test data hash ref, sum count hash ref, funcdata hash ref, checkdata hash
#  ref, testfncdata hash ref, sumfnccount hash ref, testbrdata hash ref,
#  sumbrcount hash ref, lines found, lines hit, functions found,
#  functions hit, branches found, branches hit)
#

sub get_info_entry($)
{
    my $testdata_ref = $_[0]->{"test"};
    my $sumcount_ref = $_[0]->{"sum"};
    my $funcdata_ref = $_[0]->{"func"};
    my $checkdata_ref = $_[0]->{"check"};
    my $testfncdata = $_[0]->{"testfnc"};
    my $sumfnccount = $_[0]->{"sumfnc"};
    my $testbrdata = $_[0]->{"testbr"};
    my $sumbrcount = $_[0]->{"sumbr"};
    my $lines_found = $_[0]->{"found"};
    my $lines_hit = $_[0]->{"hit"};
    my $f_found = $_[0]->{"f_found"};
    my $f_hit = $_[0]->{"f_hit"};
    my $br_found = $_[0]->{"b_found"};
    my $br_hit = $_[0]->{"b_hit"};

    return ($testdata_ref, $sumcount_ref, $funcdata_ref, $checkdata_ref,
        $testfncdata, $sumfnccount, $testbrdata, $sumbrcount,
        $lines_found, $lines_hit, $f_found, $f_hit,
        $br_found, $br_hit);
}


#
# set_info_entry(hash_ref, testdata_ref, sumcount_ref, funcdata_ref,
#                checkdata_ref, testfncdata_ref, sumfcncount_ref,
#                testbrdata_ref, sumbrcount_ref[,lines_found,
#                lines_hit, f_found, f_hit, $b_found, $b_hit])
#
# Update the hash referenced by HASH_REF with the provided data references.
#

sub set_info_entry($$$$$$$$$;$$$$$$)
{
    my $data_ref = $_[0];

    $data_ref->{"test"} = $_[1];
    $data_ref->{"sum"} = $_[2];
    $data_ref->{"func"} = $_[3];
    $data_ref->{"check"} = $_[4];
    $data_ref->{"testfnc"} = $_[5];
    $data_ref->{"sumfnc"} = $_[6];
    $data_ref->{"testbr"} = $_[7];
    $data_ref->{"sumbr"} = $_[8];

    if (defined($_[9])) { $data_ref->{"found"} = $_[9]; }
    if (defined($_[10])) { $data_ref->{"hit"} = $_[10]; }
    if (defined($_[11])) { $data_ref->{"f_found"} = $_[11]; }
    if (defined($_[12])) { $data_ref->{"f_hit"} = $_[12]; }
    if (defined($_[13])) { $data_ref->{"b_found"} = $_[13]; }
    if (defined($_[14])) { $data_ref->{"b_hit"} = $_[14]; }
}


#
# add_counts(data1_ref, data2_ref)
#
# DATA1_REF and DATA2_REF are references to hashes containing a mapping
#
#   line number -> execution count
#
# Return a list (RESULT_REF, LINES_FOUND, LINES_HIT) where RESULT_REF
# is a reference to a hash containing the combined mapping in which
# execution counts are added.
#

sub add_counts($$)
{
    my $data1_ref = $_[0];    # Hash 1
    my $data2_ref = $_[1];    # Hash 2
    my %result;        # Resulting hash
    my $line;        # Current line iteration scalar
    my $data1_count;    # Count of line in hash1
    my $data2_count;    # Count of line in hash2
    my $found = 0;        # Total number of lines found
    my $hit = 0;        # Number of lines with a count > 0

    foreach $line (keys(%$data1_ref))
    {
        $data1_count = $data1_ref->{$line};
        $data2_count = $data2_ref->{$line};

        # Add counts if present in both hashes
        if (defined($data2_count)) { $data1_count += $data2_count; }

        # Store sum in %result
        $result{$line} = $data1_count;

        $found++;
        if ($data1_count > 0) { $hit++; }
    }

    # Add lines unique to data2_ref
    foreach $line (keys(%$data2_ref))
    {
        # Skip lines already in data1_ref
        if (defined($data1_ref->{$line})) { next; }

        # Copy count from data2_ref
        $result{$line} = $data2_ref->{$line};

        $found++;
        if ($result{$line} > 0) { $hit++; }
    }

    return (\%result, $found, $hit);
}


#
# merge_checksums(ref1, ref2, filename)
#
# REF1 and REF2 are references to hashes containing a mapping
#
#   line number -> checksum
#
# Merge checksum lists defined in REF1 and REF2 and return reference to
# resulting hash. Die if a checksum for a line is defined in both hashes
# but does not match.
#

sub merge_checksums($$$)
{
    my $ref1 = $_[0];
    my $ref2 = $_[1];
    my $filename = $_[2];
    my %result;
    my $line;

    foreach $line (keys(%{$ref1}))
    {
        if (defined($ref2->{$line}) &&
            ($ref1->{$line} ne $ref2->{$line}))
        {
            die("ERROR: checksum mismatch at $filename:$line\n");
        }
        $result{$line} = $ref1->{$line};
    }

    foreach $line (keys(%{$ref2}))
    {
        $result{$line} = $ref2->{$line};
    }

    return \%result;
}


#
# merge_func_data(funcdata1, funcdata2, filename)
#

sub merge_func_data($$$)
{
    my ($funcdata1, $funcdata2, $filename) = @_;
    my %result;
    my $func;

    if (defined($funcdata1)) {
        %result = %{$funcdata1};
    }

    foreach $func (keys(%{$funcdata2})) {
        my $line1 = $result{$func};
        my $line2 = $funcdata2->{$func};

        if (defined($line1) && ($line1 != $line2)) {
            warn("WARNING: function data mismatch at ".
                 "$filename:$line2\n");
            next;
        }
        $result{$func} = $line2;
    }

    return \%result;
}


#
# add_fnccount(fnccount1, fnccount2)
#
# Add function call count data. Return list (fnccount_added, f_found, f_hit)
#

sub add_fnccount($$)
{
    my ($fnccount1, $fnccount2) = @_;
    my %result;
    my $f_found;
    my $f_hit;
    my $function;

    if (defined($fnccount1)) {
        %result = %{$fnccount1};
    }
    foreach $function (keys(%{$fnccount2})) {
        $result{$function} += $fnccount2->{$function};
    }
    $f_found = scalar(keys(%result));
    $f_hit = 0;
    foreach $function (keys(%result)) {
        if ($result{$function} > 0) {
            $f_hit++;
        }
    }

    return (\%result, $f_found, $f_hit);
}

#
# add_testfncdata(testfncdata1, testfncdata2)
#
# Add function call count data for several tests. Return reference to
# added_testfncdata.
#

sub add_testfncdata($$)
{
    my ($testfncdata1, $testfncdata2) = @_;
    my %result;
    my $testname;

    foreach $testname (keys(%{$testfncdata1})) {
        if (defined($testfncdata2->{$testname})) {
            my $fnccount;

            # Function call count data for this testname exists
            # in both data sets: merge
            ($fnccount) = add_fnccount(
                $testfncdata1->{$testname},
                $testfncdata2->{$testname});
            $result{$testname} = $fnccount;
            next;
        }
        # Function call count data for this testname is unique to
        # data set 1: copy
        $result{$testname} = $testfncdata1->{$testname};
    }

    # Add count data for testnames unique to data set 2
    foreach $testname (keys(%{$testfncdata2})) {
        if (!defined($result{$testname})) {
            $result{$testname} = $testfncdata2->{$testname};
        }
    }
    return \%result;
}


#
# brcount_to_db(brcount)
#
# Convert brcount data to the following format:
#
# db:          line number    -> block hash
# block hash:  block number   -> branch hash
# branch hash: branch number  -> taken value
#

sub brcount_to_db($)
{
    my ($brcount) = @_;
    my $line;
    my $db;

    # Add branches from first count to database
    foreach $line (keys(%{$brcount})) {
        my $brdata = $brcount->{$line};
        my $i;
        my $num = br_ivec_len($brdata);

        for ($i = 0; $i < $num; $i++) {
            my ($block, $branch, $taken) = br_ivec_get($brdata, $i);

            $db->{$line}->{$block}->{$branch} = $taken;
        }
    }

    return $db;
}


#
# db_to_brcount(db)
#
# Convert branch coverage data back to brcount format.
#

sub db_to_brcount($)
{
    my ($db) = @_;
    my $line;
    my $brcount = {};
    my $br_found = 0;
    my $br_hit = 0;

    # Convert database back to brcount format
    foreach $line (sort({$a <=> $b} keys(%{$db}))) {
        my $ldata = $db->{$line};
        my $brdata;
        my $block;

        foreach $block (sort({$a <=> $b} keys(%{$ldata}))) {
            my $bdata = $ldata->{$block};
            my $branch;

            foreach $branch (sort({$a <=> $b} keys(%{$bdata}))) {
                my $taken = $bdata->{$branch};

                $br_found++;
                $br_hit++ if ($taken ne "-" && $taken > 0);
                $brdata = br_ivec_push($brdata, $block,
                               $branch, $taken);
            }
        }
        $brcount->{$line} = $brdata;
    }

    return ($brcount, $br_found, $br_hit);
}


# combine_brcount(brcount1, brcount2, type)
#
# If add is BR_ADD, add branch coverage data and return list (brcount_added,
# br_found, br_hit). If add is BR_SUB, subtract the taken values of brcount2
# from brcount1 and return (brcount_sub, br_found, br_hit).
#

sub combine_brcount($$$)
{
    my ($brcount1, $brcount2, $type) = @_;
    my $line;
    my $block;
    my $branch;
    my $taken;
    my $db;
    my $br_found = 0;
    my $br_hit = 0;
    my $result;

    # Convert branches from first count to database
    $db = brcount_to_db($brcount1);
    # Combine values from database and second count
    foreach $line (keys(%{$brcount2})) {
        my $brdata = $brcount2->{$line};
        my $num = br_ivec_len($brdata);
        my $i;

        for ($i = 0; $i < $num; $i++) {
            ($block, $branch, $taken) = br_ivec_get($brdata, $i);
            my $new_taken = $db->{$line}->{$block}->{$branch};

            if ($type == $BR_ADD) {
                $new_taken = br_taken_add($new_taken, $taken);
            } elsif ($type == $BR_SUB) {
                $new_taken = br_taken_sub($new_taken, $taken);
            }
            $db->{$line}->{$block}->{$branch} = $new_taken
                if (defined($new_taken));
        }
    }
    # Convert database back to brcount format
    ($result, $br_found, $br_hit) = db_to_brcount($db);

    return ($result, $br_found, $br_hit);
}


#
# add_testbrdata(testbrdata1, testbrdata2)
#
# Add branch coverage data for several tests. Return reference to
# added_testbrdata.
#

sub add_testbrdata($$)
{
    my ($testbrdata1, $testbrdata2) = @_;
    my %result;
    my $testname;

    foreach $testname (keys(%{$testbrdata1})) {
        if (defined($testbrdata2->{$testname})) {
            my $brcount;

            # Branch coverage data for this testname exists
            # in both data sets: add
            ($brcount) = combine_brcount(
                $testbrdata1->{$testname},
                $testbrdata2->{$testname}, $BR_ADD);
            $result{$testname} = $brcount;
            next;
        }
        # Branch coverage data for this testname is unique to
        # data set 1: copy
        $result{$testname} = $testbrdata1->{$testname};
    }

    # Add count data for testnames unique to data set 2
    foreach $testname (keys(%{$testbrdata2})) {
        if (!defined($result{$testname})) {
            $result{$testname} = $testbrdata2->{$testname};
        }
    }
    return \%result;
}


#
# combine_info_entries(entry_ref1, entry_ref2, filename)
#
# Combine .info data entry hashes referenced by ENTRY_REF1 and ENTRY_REF2.
# Return reference to resulting hash.
#

sub combine_info_entries($$$)
{
    my $entry1 = $_[0];    # Reference to hash containing first entry
    my $testdata1;
    my $sumcount1;
    my $funcdata1;
    my $checkdata1;
    my $testfncdata1;
    my $sumfnccount1;
    my $testbrdata1;
    my $sumbrcount1;

    my $entry2 = $_[1];    # Reference to hash containing second entry
    my $testdata2;
    my $sumcount2;
    my $funcdata2;
    my $checkdata2;
    my $testfncdata2;
    my $sumfnccount2;
    my $testbrdata2;
    my $sumbrcount2;

    my %result;        # Hash containing combined entry
    my %result_testdata;
    my $result_sumcount = {};
    my $result_funcdata;
    my $result_testfncdata;
    my $result_sumfnccount;
    my $result_testbrdata;
    my $result_sumbrcount;
    my $lines_found;
    my $lines_hit;
    my $f_found;
    my $f_hit;
    my $br_found;
    my $br_hit;

    my $testname;
    my $filename = $_[2];

    # Retrieve data
    ($testdata1, $sumcount1, $funcdata1, $checkdata1, $testfncdata1,
     $sumfnccount1, $testbrdata1, $sumbrcount1) = get_info_entry($entry1);
    ($testdata2, $sumcount2, $funcdata2, $checkdata2, $testfncdata2,
     $sumfnccount2, $testbrdata2, $sumbrcount2) = get_info_entry($entry2);

    # Merge checksums
    $checkdata1 = merge_checksums($checkdata1, $checkdata2, $filename);

    # Combine funcdata
    $result_funcdata = merge_func_data($funcdata1, $funcdata2, $filename);

    # Combine function call count data
    $result_testfncdata = add_testfncdata($testfncdata1, $testfncdata2);
    ($result_sumfnccount, $f_found, $f_hit) =
        add_fnccount($sumfnccount1, $sumfnccount2);

    # Combine branch coverage data
    $result_testbrdata = add_testbrdata($testbrdata1, $testbrdata2);
    ($result_sumbrcount, $br_found, $br_hit) =
        combine_brcount($sumbrcount1, $sumbrcount2, $BR_ADD);

    # Combine testdata
    foreach $testname (keys(%{$testdata1}))
    {
        if (defined($testdata2->{$testname}))
        {
            # testname is present in both entries, requires
            # combination
            ($result_testdata{$testname}) =
                add_counts($testdata1->{$testname},
                       $testdata2->{$testname});
        }
        else
        {
            # testname only present in entry1, add to result
            $result_testdata{$testname} = $testdata1->{$testname};
        }

        # update sum count hash
        ($result_sumcount, $lines_found, $lines_hit) =
            add_counts($result_sumcount,
                   $result_testdata{$testname});
    }

    foreach $testname (keys(%{$testdata2}))
    {
        # Skip testnames already covered by previous iteration
        if (defined($testdata1->{$testname})) { next; }

        # testname only present in entry2, add to result hash
        $result_testdata{$testname} = $testdata2->{$testname};

        # update sum count hash
        ($result_sumcount, $lines_found, $lines_hit) =
            add_counts($result_sumcount,
                   $result_testdata{$testname});
    }
    
    # Calculate resulting sumcount

    # Store result
    set_info_entry(\%result, \%result_testdata, $result_sumcount,
               $result_funcdata, $checkdata1, $result_testfncdata,
               $result_sumfnccount, $result_testbrdata,
               $result_sumbrcount, $lines_found, $lines_hit,
               $f_found, $f_hit, $br_found, $br_hit);

    return(\%result);
}


#
# combine_info_files(info_ref1, info_ref2)
#
# Combine .info data in hashes referenced by INFO_REF1 and INFO_REF2. Return
# reference to resulting hash.
#

sub combine_info_files($$)
{
    my %hash1 = %{$_[0]};
    my %hash2 = %{$_[1]};
    my $filename;

    foreach $filename (keys(%hash2))
    {
        if ($hash1{$filename})
        {
            # Entry already exists in hash1, combine them
            $hash1{$filename} =
                combine_info_entries($hash1{$filename},
                             $hash2{$filename},
                             $filename);
        }
        else
        {
            # Entry is unique in both hashes, simply add to
            # resulting hash
            $hash1{$filename} = $hash2{$filename};
        }
    }

    return(\%hash1);
}


#
# add_traces()
#

sub add_traces()
{
    my $total_trace;
    my $current_trace;
    my $tracefile;
    my @result;
    local *INFO_HANDLE;

    info("Combining tracefiles.\n");

    foreach $tracefile (@add_tracefile)
    {
        $current_trace = read_info_file($tracefile);
        if ($total_trace)
        {
            $total_trace = combine_info_files($total_trace,
                              $current_trace);
        }
        else
        {
            $total_trace = $current_trace;
        }
    }

    # Write combined data
    if ($to_file)
    {
        info("Writing data to $output_filename\n");
        open(INFO_HANDLE, ">", $output_filename)
            or die("ERROR: cannot write to $output_filename!\n");
        @result = write_info_file(*INFO_HANDLE, $total_trace);
        close(*INFO_HANDLE);
    }
    else
    {
        @result = write_info_file(*STDOUT, $total_trace);
    }

    return @result;
}


#
# write_info_file(filehandle, data)
#

sub write_info_file(*$)
{
    local *INFO_HANDLE = $_[0];
    my %data = %{$_[1]};
    my $source_file;
    my $entry;
    my $testdata;
    my $sumcount;
    my $funcdata;
    my $checkdata;
    my $testfncdata;
    my $sumfnccount;
    my $testbrdata;
    my $sumbrcount;
    my $testname;
    my $line;
    my $func;
    my $testcount;
    my $testfnccount;
    my $testbrcount;
    my $found;
    my $hit;
    my $f_found;
    my $f_hit;
    my $br_found;
    my $br_hit;
    my $ln_total_found = 0;
    my $ln_total_hit = 0;
    my $fn_total_found = 0;
    my $fn_total_hit = 0;
    my $br_total_found = 0;
    my $br_total_hit = 0;

    foreach $source_file (sort(keys(%data)))
    {
        $entry = $data{$source_file};
        ($testdata, $sumcount, $funcdata, $checkdata, $testfncdata,
         $sumfnccount, $testbrdata, $sumbrcount, $found, $hit,
         $f_found, $f_hit, $br_found, $br_hit) =
            get_info_entry($entry);

        # Add to totals
        $ln_total_found += $found;
        $ln_total_hit += $hit;
        $fn_total_found += $f_found;
        $fn_total_hit += $f_hit;
        $br_total_found += $br_found;
        $br_total_hit += $br_hit;

        foreach $testname (sort(keys(%{$testdata})))
        {
            $testcount = $testdata->{$testname};
            $testfnccount = $testfncdata->{$testname};
            $testbrcount = $testbrdata->{$testname};
            $found = 0;
            $hit   = 0;

            print(INFO_HANDLE "TN:$testname\n");
            print(INFO_HANDLE "SF:$source_file\n");

            # Write function related data
            foreach $func (
                sort({$funcdata->{$a} <=> $funcdata->{$b}}
                keys(%{$funcdata})))
            {
                print(INFO_HANDLE "FN:".$funcdata->{$func}.
                      ",$func\n");
            }
            foreach $func (keys(%{$testfnccount})) {
                print(INFO_HANDLE "FNDA:".
                      $testfnccount->{$func}.
                      ",$func\n");
            }
            ($f_found, $f_hit) =
                get_func_found_and_hit($testfnccount);
            print(INFO_HANDLE "FNF:$f_found\n");
            print(INFO_HANDLE "FNH:$f_hit\n");

            # Write branch related data
            $br_found = 0;
            $br_hit = 0;
            foreach $line (sort({$a <=> $b}
                        keys(%{$testbrcount}))) {
                my $brdata = $testbrcount->{$line};
                my $num = br_ivec_len($brdata);
                my $i;

                for ($i = 0; $i < $num; $i++) {
                    my ($block, $branch, $taken) =
                        br_ivec_get($brdata, $i);

                    $block = $BR_VEC_MAX if ($block < 0);
                    print(INFO_HANDLE "BRDA:$line,$block,".
                          "$branch,$taken\n");
                    $br_found++;
                    $br_hit++ if ($taken ne '-' &&
                              $taken > 0);
                }
            }
            if ($br_found > 0) {
                print(INFO_HANDLE "BRF:$br_found\n");
                print(INFO_HANDLE "BRH:$br_hit\n");
            }

            # Write line related data
            foreach $line (sort({$a <=> $b} keys(%{$testcount})))
            {
                print(INFO_HANDLE "DA:$line,".
                      $testcount->{$line}.
                      (defined($checkdata->{$line}) &&
                       $checksum ?
                       ",".$checkdata->{$line} : "")."\n");
                $found++;
                if ($testcount->{$line} > 0)
                {
                    $hit++;
                }

            }
            print(INFO_HANDLE "LF:$found\n");
            print(INFO_HANDLE "LH:$hit\n");
            print(INFO_HANDLE "end_of_record\n");
        }
    }

    return ($ln_total_found, $ln_total_hit, $fn_total_found, $fn_total_hit,
        $br_total_found, $br_total_hit);
}


#
# transform_pattern(pattern)
#
# Transform shell wildcard expression to equivalent Perl regular expression.
# Return transformed pattern.
#

sub transform_pattern($)
{
    my $pattern = $_[0];

    # Escape special chars

    $pattern =~ s/\\/\\\\/g;
    $pattern =~ s/\//\\\//g;
    $pattern =~ s/\^/\\\^/g;
    $pattern =~ s/\$/\\\$/g;
    $pattern =~ s/\(/\\\(/g;
    $pattern =~ s/\)/\\\)/g;
    $pattern =~ s/\[/\\\[/g;
    $pattern =~ s/\]/\\\]/g;
    $pattern =~ s/\{/\\\{/g;
    $pattern =~ s/\}/\\\}/g;
    $pattern =~ s/\./\\\./g;
    $pattern =~ s/\,/\\\,/g;
    $pattern =~ s/\|/\\\|/g;
    $pattern =~ s/\+/\\\+/g;
    $pattern =~ s/\!/\\\!/g;

    # Transform ? => (.) and * => (.*)

    $pattern =~ s/\*/\(\.\*\)/g;
    $pattern =~ s/\?/\(\.\)/g;

    return $pattern;
}


#
# extract()
#

sub extract()
{
    my $data = read_info_file($extract);
    my $filename;
    my $keep;
    my $pattern;
    my @pattern_list;
    my $extracted = 0;
    my @result;
    local *INFO_HANDLE;

    # Need perlreg expressions instead of shell pattern
    @pattern_list = map({ transform_pattern($_); } @ARGV);

    # Filter out files which do not match any pattern
    foreach $filename (sort(keys(%{$data})))
    {
        $keep = 0;

        foreach $pattern (@pattern_list)
        {
            $keep ||= ($filename =~ (/^$pattern$/));
        }


        if (!$keep)
        {
            delete($data->{$filename});
        }
        else
        {
            info("Extracting $filename\n"),
            $extracted++;
        }
    }

    # Write extracted data
    if ($to_file)
    {
        info("Extracted $extracted files\n");
        info("Writing data to $output_filename\n");
        open(INFO_HANDLE, ">", $output_filename)
            or die("ERROR: cannot write to $output_filename!\n");
        @result = write_info_file(*INFO_HANDLE, $data);
        close(*INFO_HANDLE);
    }
    else
    {
        @result = write_info_file(*STDOUT, $data);
    }

    return @result;
}


#
# remove()
#

sub remove()
{
    my $data = read_info_file($remove);
    my $filename;
    my $match_found;
    my $pattern;
    my @pattern_list;
    my $removed = 0;
    my @result;
    local *INFO_HANDLE;

    # Need perlreg expressions instead of shell pattern
    @pattern_list = map({ transform_pattern($_); } @ARGV);

    # Filter out files that match the pattern
    foreach $filename (sort(keys(%{$data})))
    {
        $match_found = 0;

        foreach $pattern (@pattern_list)
        {
            $match_found ||= ($filename =~ (/$pattern$/));
        }


        if ($match_found)
        {
            delete($data->{$filename});
            info("Removing $filename\n"),
            $removed++;
        }
    }

    # Write data
    if ($to_file)
    {
        info("Deleted $removed files\n");
        info("Writing data to $output_filename\n");
        open(INFO_HANDLE, ">", $output_filename)
            or die("ERROR: cannot write to $output_filename!\n");
        @result = write_info_file(*INFO_HANDLE, $data);
        close(*INFO_HANDLE);
    }
    else
    {
        @result = write_info_file(*STDOUT, $data);
    }

    return @result;
}


# get_prefix(max_width, max_percentage_too_long, path_list)
#
# Return a path prefix that satisfies the following requirements:
# - is shared by more paths in path_list than any other prefix
# - the percentage of paths which would exceed the given max_width length
#   after applying the prefix does not exceed max_percentage_too_long
#
# If multiple prefixes satisfy all requirements, the longest prefix is
# returned. Return an empty string if no prefix could be found.

sub get_prefix($$@)
{
    my ($max_width, $max_long, @path_list) = @_;
    my $path;
    my $ENTRY_NUM = 0;
    my $ENTRY_LONG = 1;
    my %prefix;

    # Build prefix hash
    foreach $path (@path_list) {
        my ($v, $d, $f) = splitpath($path);
        my @dirs = splitdir($d);
        my $p_len = length($path);
        my $i;

        # Remove trailing '/'
        pop(@dirs) if ($dirs[scalar(@dirs) - 1] eq '');
        for ($i = 0; $i < scalar(@dirs); $i++) {
            my $subpath = catpath($v, catdir(@dirs[0..$i]), '');
            my $entry = $prefix{$subpath};

            $entry = [ 0, 0 ] if (!defined($entry));
            $entry->[$ENTRY_NUM]++;
            if (($p_len - length($subpath) - 1) > $max_width) {
                $entry->[$ENTRY_LONG]++;
            }
            $prefix{$subpath} = $entry;
        }
    }
    # Find suitable prefix (sort descending by two keys: 1. number of
    # entries covered by a prefix, 2. length of prefix)
    foreach $path (sort {($prefix{$a}->[$ENTRY_NUM] ==
                  $prefix{$b}->[$ENTRY_NUM]) ?
                length($b) <=> length($a) :
                $prefix{$b}->[$ENTRY_NUM] <=>
                $prefix{$a}->[$ENTRY_NUM]}
                keys(%prefix)) {
        my ($num, $long) = @{$prefix{$path}};

        # Check for additional requirement: number of filenames
        # that would be too long may not exceed a certain percentage
        if ($long <= $num * $max_long / 100) {
            return $path;
        }
    }

    return "";
}


#
# shorten_filename(filename, width)
#
# Truncate filename if it is longer than width characters.
#

sub shorten_filename($$)
{
    my ($filename, $width) = @_;
    my $l = length($filename);
    my $s;
    my $e;

    return $filename if ($l <= $width);
    $e = int(($width - 3) / 2);
    $s = $width - 3 - $e;

    return substr($filename, 0, $s).'...'.substr($filename, $l - $e);
}


sub shorten_number($$)
{
    my ($number, $width) = @_;
    my $result = sprintf("%*d", $width, $number);

    return $result if (length($result) <= $width);
    $number = $number / 1000;
    return $result if (length($result) <= $width);
    $result = sprintf("%*dk", $width - 1, $number);
    return $result if (length($result) <= $width);
    $number = $number / 1000;
    $result = sprintf("%*dM", $width - 1, $number);
    return $result if (length($result) <= $width);
    return '#';
}

sub shorten_rate($$$)
{
    my ($hit, $found, $width) = @_;
    my $result = rate($hit, $found, "%", 1, $width);

    return $result if (length($result) <= $width);
    $result = rate($hit, $found, "%", 0, $width);
    return $result if (length($result) <= $width);
    return "#";
}

#
# list()
#

sub list()
{
    my $data = read_info_file($list);
    my $filename;
    my $found;
    my $hit;
    my $entry;
    my $fn_found;
    my $fn_hit;
    my $br_found;
    my $br_hit;
    my $total_found = 0;
    my $total_hit = 0;
    my $fn_total_found = 0;
    my $fn_total_hit = 0;
    my $br_total_found = 0;
    my $br_total_hit = 0;
    my $prefix;
    my $strlen = length("Filename");
    my $format;
    my $heading1;
    my $heading2;
    my @footer;
    my $barlen;
    my $rate;
    my $fnrate;
    my $brrate;
    my $lastpath;
    my $F_LN_NUM = 0;
    my $F_LN_RATE = 1;
    my $F_FN_NUM = 2;
    my $F_FN_RATE = 3;
    my $F_BR_NUM = 4;
    my $F_BR_RATE = 5;
    my @fwidth_narrow = (5, 5, 3, 5, 4, 5);
    my @fwidth_wide = (6, 5, 5, 5, 6, 5);
    my @fwidth = @fwidth_wide;
    my $w;
    my $max_width = $opt_list_width;
    my $max_long = $opt_list_truncate_max;
    my $fwidth_narrow_length;
    my $fwidth_wide_length;
    my $got_prefix = 0;
    my $root_prefix = 0;

    # Calculate total width of narrow fields
    $fwidth_narrow_length = 0;
    foreach $w (@fwidth_narrow) {
        $fwidth_narrow_length += $w + 1;
    }
    # Calculate total width of wide fields
    $fwidth_wide_length = 0;
    foreach $w (@fwidth_wide) {
        $fwidth_wide_length += $w + 1;
    }
    # Get common file path prefix
    $prefix = get_prefix($max_width - $fwidth_narrow_length, $max_long,
                 keys(%{$data}));
    $root_prefix = 1 if ($prefix eq rootdir());
    $got_prefix = 1 if (length($prefix) > 0);
    $prefix =~ s/\/$//;
    # Get longest filename length
    foreach $filename (keys(%{$data})) {
        if (!$opt_list_full_path) {
            if (!$got_prefix || !$root_prefix &&
                !($filename =~ s/^\Q$prefix\/\E//)) {
                my ($v, $d, $f) = splitpath($filename);

                $filename = $f;
            }
        }
        # Determine maximum length of entries
        if (length($filename) > $strlen) {
            $strlen = length($filename)
        }
    }
    if (!$opt_list_full_path) {
        my $blanks;

        $w = $fwidth_wide_length;
        # Check if all columns fit into max_width characters
        if ($strlen + $fwidth_wide_length > $max_width) {
            # Use narrow fields
            @fwidth = @fwidth_narrow;
            $w = $fwidth_narrow_length;
            if (($strlen + $fwidth_narrow_length) > $max_width) {
                # Truncate filenames at max width
                $strlen = $max_width - $fwidth_narrow_length;
            }
        }
        # Add some blanks between filename and fields if possible
        $blanks = int($strlen * 0.5);
        $blanks = 4 if ($blanks < 4);
        $blanks = 8 if ($blanks > 8);
        if (($strlen + $w + $blanks) < $max_width) {
            $strlen += $blanks;
        } else {
            $strlen = $max_width - $w;
        }
    }
    # Filename
    $w = $strlen;
    $format        = "%-${w}s|";
    $heading1     = sprintf("%*s|", $w, "");
    $heading2     = sprintf("%-*s|", $w, "Filename");
    $barlen        = $w + 1;
    # Line coverage rate
    $w = $fwidth[$F_LN_RATE];
    $format        .= "%${w}s ";
    $heading1     .= sprintf("%-*s |", $w + $fwidth[$F_LN_NUM],
                   "Lines");
    $heading2     .= sprintf("%-*s ", $w, "Rate");
    $barlen        += $w + 1;
    # Number of lines
    $w = $fwidth[$F_LN_NUM];
    $format        .= "%${w}s|";
    $heading2    .= sprintf("%*s|", $w, "Num");
    $barlen        += $w + 1;
    # Function coverage rate
    $w = $fwidth[$F_FN_RATE];
    $format        .= "%${w}s ";
    $heading1     .= sprintf("%-*s|", $w + $fwidth[$F_FN_NUM] + 1,
                   "Functions");
    $heading2     .= sprintf("%-*s ", $w, "Rate");
    $barlen        += $w + 1;
    # Number of functions
    $w = $fwidth[$F_FN_NUM];
    $format        .= "%${w}s|";
    $heading2    .= sprintf("%*s|", $w, "Num");
    $barlen        += $w + 1;
    # Branch coverage rate
    $w = $fwidth[$F_BR_RATE];
    $format        .= "%${w}s ";
    $heading1     .= sprintf("%-*s", $w + $fwidth[$F_BR_NUM] + 1,
                   "Branches");
    $heading2     .= sprintf("%-*s ", $w, "Rate");
    $barlen        += $w + 1;
    # Number of branches
    $w = $fwidth[$F_BR_NUM];
    $format        .= "%${w}s";
    $heading2    .= sprintf("%*s", $w, "Num");
    $barlen        += $w;
    # Line end
    $format        .= "\n";
    $heading1    .= "\n";
    $heading2    .= "\n";

    # Print heading
    print($heading1);
    print($heading2);
    print(("="x$barlen)."\n");

    # Print per file information
    foreach $filename (sort(keys(%{$data})))
    {
        my @file_data;
        my $print_filename = $filename;

        $entry = $data->{$filename};
        if (!$opt_list_full_path) {
            my $p;

            $print_filename = $filename;
            if (!$got_prefix || !$root_prefix &&
                !($print_filename =~ s/^\Q$prefix\/\E//)) {
                my ($v, $d, $f) = splitpath($filename);

                $p = catpath($v, $d, "");
                $p =~ s/\/$//;
                $print_filename = $f;
            } else {
                $p = $prefix;
            }

            if (!defined($lastpath) || $lastpath ne $p) {
                print("\n") if (defined($lastpath));
                $lastpath = $p;
                print("[$lastpath/]\n") if (!$root_prefix);
            }
            $print_filename = shorten_filename($print_filename,
                               $strlen);
        }

        (undef, undef, undef, undef, undef, undef, undef, undef,
         $found, $hit, $fn_found, $fn_hit, $br_found, $br_hit) =
            get_info_entry($entry);

        # Assume zero count if there is no function data for this file
        if (!defined($fn_found) || !defined($fn_hit)) {
            $fn_found = 0;
            $fn_hit = 0;
        }
        # Assume zero count if there is no branch data for this file
        if (!defined($br_found) || !defined($br_hit)) {
            $br_found = 0;
            $br_hit = 0;
        }

        # Add line coverage totals
        $total_found += $found;
        $total_hit += $hit;
        # Add function coverage totals
        $fn_total_found += $fn_found;
        $fn_total_hit += $fn_hit;
        # Add branch coverage totals
        $br_total_found += $br_found;
        $br_total_hit += $br_hit;

        # Determine line coverage rate for this file
        $rate = shorten_rate($hit, $found, $fwidth[$F_LN_RATE]);
        # Determine function coverage rate for this file
        $fnrate = shorten_rate($fn_hit, $fn_found, $fwidth[$F_FN_RATE]);
        # Determine branch coverage rate for this file
        $brrate = shorten_rate($br_hit, $br_found, $fwidth[$F_BR_RATE]);

        # Assemble line parameters
        push(@file_data, $print_filename);
        push(@file_data, $rate);
        push(@file_data, shorten_number($found, $fwidth[$F_LN_NUM]));
        push(@file_data, $fnrate);
        push(@file_data, shorten_number($fn_found, $fwidth[$F_FN_NUM]));
        push(@file_data, $brrate);
        push(@file_data, shorten_number($br_found, $fwidth[$F_BR_NUM]));

        # Print assembled line
        printf($format, @file_data);
    }

    # Determine total line coverage rate
    $rate = shorten_rate($total_hit, $total_found, $fwidth[$F_LN_RATE]);
    # Determine total function coverage rate
    $fnrate = shorten_rate($fn_total_hit, $fn_total_found,
                   $fwidth[$F_FN_RATE]);
    # Determine total branch coverage rate
    $brrate = shorten_rate($br_total_hit, $br_total_found,
                   $fwidth[$F_BR_RATE]);

    # Print separator
    print(("="x$barlen)."\n");

    # Assemble line parameters
    push(@footer, sprintf("%*s", $strlen, "Total:"));
    push(@footer, $rate);
    push(@footer, shorten_number($total_found, $fwidth[$F_LN_NUM]));
    push(@footer, $fnrate);
    push(@footer, shorten_number($fn_total_found, $fwidth[$F_FN_NUM]));
    push(@footer, $brrate);
    push(@footer, shorten_number($br_total_found, $fwidth[$F_BR_NUM]));

    # Print assembled line
    printf($format, @footer);
}


#
# get_common_filename(filename1, filename2)
#
# Check for filename components which are common to FILENAME1 and FILENAME2.
# Upon success, return
#
#   (common, path1, path2)
#
#  or 'undef' in case there are no such parts.
#

sub get_common_filename($$)
{
        my @list1 = split("/", $_[0]);
        my @list2 = split("/", $_[1]);
    my @result;

    # Work in reverse order, i.e. beginning with the filename itself
    while (@list1 && @list2 && ($list1[$#list1] eq $list2[$#list2]))
    {
        unshift(@result, pop(@list1));
        pop(@list2);
    }

    # Did we find any similarities?
    if (scalar(@result) > 0)
    {
            return (join("/", @result), join("/", @list1),
            join("/", @list2));
    }
    else
    {
        return undef;
    }
}


#
# strip_directories($path, $depth)
#
# Remove DEPTH leading directory levels from PATH.
#

sub strip_directories($$)
{
    my $filename = $_[0];
    my $depth = $_[1];
    my $i;

    if (!defined($depth) || ($depth < 1))
    {
        return $filename;
    }
    for ($i = 0; $i < $depth; $i++)
    {
        $filename =~ s/^[^\/]*\/+(.*)$/$1/;
    }
    return $filename;
}


#
# read_diff(filename)
#
# Read diff output from FILENAME to memory. The diff file has to follow the
# format generated by 'diff -u'. Returns a list of hash references:
#
#   (mapping, path mapping)
#
#   mapping:   filename -> reference to line hash
#   line hash: line number in new file -> corresponding line number in old file
#
#   path mapping:  filename -> old filename
#
# Die in case of error.
#

sub read_diff($)
{
    my $diff_file = $_[0];    # Name of diff file
    my %diff;        # Resulting mapping filename -> line hash
    my %paths;        # Resulting mapping old path  -> new path
    my $mapping;        # Reference to current line hash
    my $line;        # Contents of current line
    my $num_old;        # Current line number in old file
    my $num_new;        # Current line number in new file
    my $file_old;        # Name of old file in diff section
    my $file_new;        # Name of new file in diff section
    my $filename;        # Name of common filename of diff section
    my $in_block = 0;    # Non-zero while we are inside a diff block
    local *HANDLE;        # File handle for reading the diff file

    info("Reading diff $diff_file\n");

    # Check if file exists and is readable
    stat($diff_file);
    if (!(-r _))
    {
        die("ERROR: cannot read file $diff_file!\n");
    }

    # Check if this is really a plain file
    if (!(-f _))
    {
        die("ERROR: not a plain file: $diff_file!\n");
    }

    # Check for .gz extension
    if ($diff_file =~ /\.gz$/)
    {
        # Check for availability of GZIP tool
        system_no_output(1, "gunzip", "-h")
            and die("ERROR: gunzip command not available!\n");

        # Check integrity of compressed file
        system_no_output(1, "gunzip", "-t", $diff_file)
            and die("ERROR: integrity check failed for ".
                "compressed file $diff_file!\n");

        # Open compressed file
        open(HANDLE, "-|", "gunzip -c '$diff_file'")
            or die("ERROR: cannot start gunzip to decompress ".
                   "file $_[0]!\n");
    }
    else
    {
        # Open decompressed file
        open(HANDLE, "<", $diff_file)
            or die("ERROR: cannot read file $_[0]!\n");
    }

    # Parse diff file line by line
    while (<HANDLE>)
    {
        chomp($_);
        $line = $_;

        foreach ($line)
        {
            # Filename of old file:
            # --- <filename> <date>
            /^--- (\S+)/ && do
            {
                $file_old = strip_directories($1, $strip);
                last;
            };
            # Filename of new file:
            # +++ <filename> <date>
            /^\+\+\+ (\S+)/ && do
            {
                # Add last file to resulting hash
                if ($filename)
                {
                    my %new_hash;
                    $diff{$filename} = $mapping;
                    $mapping = \%new_hash;
                }
                $file_new = strip_directories($1, $strip);
                $filename = $file_old;
                $paths{$filename} = $file_new;
                $num_old = 1;
                $num_new = 1;
                last;
            };
            # Start of diff block:
            # @@ -old_start,old_num, +new_start,new_num @@
            /^\@\@\s+-(\d+),(\d+)\s+\+(\d+),(\d+)\s+\@\@$/ && do
            {
            $in_block = 1;
            while ($num_old < $1)
            {
                $mapping->{$num_new} = $num_old;
                $num_old++;
                $num_new++;
            }
            last;
            };
            # Unchanged line
            # <line starts with blank>
            /^ / && do
            {
                if ($in_block == 0)
                {
                    last;
                }
                $mapping->{$num_new} = $num_old;
                $num_old++;
                $num_new++;
                last;
            };
            # Line as seen in old file
            # <line starts with '-'>
            /^-/ && do
            {
                if ($in_block == 0)
                {
                    last;
                }
                $num_old++;
                last;
            };
            # Line as seen in new file
            # <line starts with '+'>
            /^\+/ && do
            {
                if ($in_block == 0)
                {
                    last;
                }
                $num_new++;
                last;
            };
            # Empty line
            /^$/ && do
            {
                if ($in_block == 0)
                {
                    last;
                }
                $mapping->{$num_new} = $num_old;
                $num_old++;
                $num_new++;
                last;
            };
        }
    }

    close(HANDLE);

    # Add final diff file section to resulting hash
    if ($filename)
    {
        $diff{$filename} = $mapping;
    }

    if (!%diff)
    {
        die("ERROR: no valid diff data found in $diff_file!\n".
            "Make sure to use 'diff -u' when generating the diff ".
            "file.\n");
    }
    return (\%diff, \%paths);
}


#
# apply_diff($count_data, $line_hash)
#
# Transform count data using a mapping of lines:
#
#   $count_data: reference to hash: line number -> data
#   $line_hash:  reference to hash: line number new -> line number old
#
# Return a reference to transformed count data.
#

sub apply_diff($$)
{
    my $count_data = $_[0];    # Reference to data hash: line -> hash
    my $line_hash = $_[1];    # Reference to line hash: new line -> old line
    my %result;        # Resulting hash
    my $last_new = 0;    # Last new line number found in line hash
    my $last_old = 0;    # Last old line number found in line hash

    # Iterate all new line numbers found in the diff
    foreach (sort({$a <=> $b} keys(%{$line_hash})))
    {
        $last_new = $_;
        $last_old = $line_hash->{$last_new};

        # Is there data associated with the corresponding old line?
        if (defined($count_data->{$line_hash->{$_}}))
        {
            # Copy data to new hash with a new line number
            $result{$_} = $count_data->{$line_hash->{$_}};
        }
    }
    # Transform all other lines which come after the last diff entry
    foreach (sort({$a <=> $b} keys(%{$count_data})))
    {
        if ($_ <= $last_old)
        {
            # Skip lines which were covered by line hash
            next;
        }
        # Copy data to new hash with an offset
        $result{$_ + ($last_new - $last_old)} = $count_data->{$_};
    }

    return \%result;
}


#
# apply_diff_to_brcount(brcount, linedata)
#
# Adjust line numbers of branch coverage data according to linedata.
#

sub apply_diff_to_brcount($$)
{
    my ($brcount, $linedata) = @_;
    my $db;

    # Convert brcount to db format
    $db = brcount_to_db($brcount);
    # Apply diff to db format
    $db = apply_diff($db, $linedata);
    # Convert db format back to brcount format
    ($brcount) = db_to_brcount($db);

    return $brcount;
}


#
# get_hash_max(hash_ref)
#
# Return the highest integer key from hash.
#

sub get_hash_max($)
{
    my ($hash) = @_;
    my $max;

    foreach (keys(%{$hash})) {
        if (!defined($max)) {
            $max = $_;
        } elsif ($hash->{$_} > $max) {
            $max = $_;
        }
    }
    return $max;
}

sub get_hash_reverse($)
{
    my ($hash) = @_;
    my %result;

    foreach (keys(%{$hash})) {
        $result{$hash->{$_}} = $_;
    }

    return \%result;
}

#
# apply_diff_to_funcdata(funcdata, line_hash)
#

sub apply_diff_to_funcdata($$)
{
    my ($funcdata, $linedata) = @_;
    my $last_new = get_hash_max($linedata);
    my $last_old = $linedata->{$last_new};
    my $func;
    my %result;
    my $line_diff = get_hash_reverse($linedata);

    foreach $func (keys(%{$funcdata})) {
        my $line = $funcdata->{$func};

        if (defined($line_diff->{$line})) {
            $result{$func} = $line_diff->{$line};
        } elsif ($line > $last_old) {
            $result{$func} = $line + $last_new - $last_old;
        }
    }

    return \%result;
}


#
# get_line_hash($filename, $diff_data, $path_data)
#
# Find line hash in DIFF_DATA which matches FILENAME. On success, return list
# line hash. or undef in case of no match. Die if more than one line hashes in
# DIFF_DATA match.
#

sub get_line_hash($$$)
{
    my $filename = $_[0];
    my $diff_data = $_[1];
    my $path_data = $_[2];
    my $conversion;
    my $old_path;
    my $new_path;
    my $diff_name;
    my $common;
    my $old_depth;
    my $new_depth;

    # Remove trailing slash from diff path
    $diff_path =~ s/\/$//;
    foreach (keys(%{$diff_data}))
    {
        my $sep = "";

        $sep = '/' if (!/^\//);

        # Try to match diff filename with filename
        if ($filename =~ /^\Q$diff_path$sep$_\E$/)
        {
            if ($diff_name)
            {
                # Two files match, choose the more specific one
                # (the one with more path components)
                $old_depth = ($diff_name =~ tr/\///);
                $new_depth = (tr/\///);
                if ($old_depth == $new_depth)
                {
                    die("ERROR: diff file contains ".
                        "ambiguous entries for ".
                        "$filename\n");
                }
                elsif ($new_depth > $old_depth)
                {
                    $diff_name = $_;
                }
            }
            else
            {
                $diff_name = $_;
            }
        };
    }
    if ($diff_name)
    {
        # Get converted path
        if ($filename =~ /^(.*)$diff_name$/)
        {
            ($common, $old_path, $new_path) =
                get_common_filename($filename,
                    $1.$path_data->{$diff_name});
        }
        return ($diff_data->{$diff_name}, $old_path, $new_path);
    }
    else
    {
        return undef;
    }
}


#
# convert_paths(trace_data, path_conversion_data)
#
# Rename all paths in TRACE_DATA which show up in PATH_CONVERSION_DATA.
#

sub convert_paths($$)
{
    my $trace_data = $_[0];
    my $path_conversion_data = $_[1];
    my $filename;
    my $new_path;

    if (scalar(keys(%{$path_conversion_data})) == 0)
    {
        info("No path conversion data available.\n");
        return;
    }

    # Expand path conversion list
    foreach $filename (keys(%{$path_conversion_data}))
    {
        $new_path = $path_conversion_data->{$filename};
        while (($filename =~ s/^(.*)\/[^\/]+$/$1/) &&
               ($new_path =~ s/^(.*)\/[^\/]+$/$1/) &&
               ($filename ne $new_path))
        {
            $path_conversion_data->{$filename} = $new_path;
        }
    }

    # Adjust paths
    FILENAME: foreach $filename (keys(%{$trace_data}))
    {
        # Find a path in our conversion table that matches, starting
        # with the longest path
        foreach (sort({length($b) <=> length($a)}
                  keys(%{$path_conversion_data})))
        {
            # Is this path a prefix of our filename?
            if (!($filename =~ /^$_(.*)$/))
            {
                next;
            }
            $new_path = $path_conversion_data->{$_}.$1;

            # Make sure not to overwrite an existing entry under
            # that path name
            if ($trace_data->{$new_path})
            {
                # Need to combine entries
                $trace_data->{$new_path} =
                    combine_info_entries(
                        $trace_data->{$filename},
                        $trace_data->{$new_path},
                        $filename);
            }
            else
            {
                # Simply rename entry
                $trace_data->{$new_path} =
                    $trace_data->{$filename};
            }
            delete($trace_data->{$filename});
            next FILENAME;
        }
        info("No conversion available for filename $filename\n");
    }
}

#
# sub adjust_fncdata(funcdata, testfncdata, sumfnccount)
#
# Remove function call count data from testfncdata and sumfnccount which
# is no longer present in funcdata.
#

sub adjust_fncdata($$$)
{
    my ($funcdata, $testfncdata, $sumfnccount) = @_;
    my $testname;
    my $func;
    my $f_found;
    my $f_hit;

    # Remove count data in testfncdata for functions which are no longer
    # in funcdata
    foreach $testname (keys(%{$testfncdata})) {
        my $fnccount = $testfncdata->{$testname};

        foreach $func (keys(%{$fnccount})) {
            if (!defined($funcdata->{$func})) {
                delete($fnccount->{$func});
            }
        }
    }
    # Remove count data in sumfnccount for functions which are no longer
    # in funcdata
    foreach $func (keys(%{$sumfnccount})) {
        if (!defined($funcdata->{$func})) {
            delete($sumfnccount->{$func});
        }
    }
}

#
# get_func_found_and_hit(sumfnccount)
#
# Return (f_found, f_hit) for sumfnccount
#

sub get_func_found_and_hit($)
{
    my ($sumfnccount) = @_;
    my $function;
    my $f_found;
    my $f_hit;

    $f_found = scalar(keys(%{$sumfnccount}));
    $f_hit = 0;
    foreach $function (keys(%{$sumfnccount})) {
        if ($sumfnccount->{$function} > 0) {
            $f_hit++;
        }
    }
    return ($f_found, $f_hit);
}

#
# diff()
#

sub diff()
{
    my $trace_data = read_info_file($diff);
    my $diff_data;
    my $path_data;
    my $old_path;
    my $new_path;
    my %path_conversion_data;
    my $filename;
    my $line_hash;
    my $new_name;
    my $entry;
    my $testdata;
    my $testname;
    my $sumcount;
    my $funcdata;
    my $checkdata;
    my $testfncdata;
    my $sumfnccount;
    my $testbrdata;
    my $sumbrcount;
    my $found;
    my $hit;
    my $f_found;
    my $f_hit;
    my $br_found;
    my $br_hit;
    my $converted = 0;
    my $unchanged = 0;
    my @result;
    local *INFO_HANDLE;

    ($diff_data, $path_data) = read_diff($ARGV[0]);

        foreach $filename (sort(keys(%{$trace_data})))
        {
        # Find a diff section corresponding to this file
        ($line_hash, $old_path, $new_path) =
            get_line_hash($filename, $diff_data, $path_data);
        if (!$line_hash)
        {
            # There's no diff section for this file
            $unchanged++;
            next;
        }
        $converted++;
        if ($old_path && $new_path && ($old_path ne $new_path))
        {
            $path_conversion_data{$old_path} = $new_path;
        }
        # Check for deleted files
        if (scalar(keys(%{$line_hash})) == 0)
        {
            info("Removing $filename\n");
            delete($trace_data->{$filename});
            next;
        }
        info("Converting $filename\n");
        $entry = $trace_data->{$filename};
        ($testdata, $sumcount, $funcdata, $checkdata, $testfncdata,
         $sumfnccount, $testbrdata, $sumbrcount) =
            get_info_entry($entry);
        # Convert test data
        foreach $testname (keys(%{$testdata}))
        {
            # Adjust line numbers of line coverage data
            $testdata->{$testname} =
                apply_diff($testdata->{$testname}, $line_hash);
            # Adjust line numbers of branch coverage data
            $testbrdata->{$testname} =
                apply_diff_to_brcount($testbrdata->{$testname},
                              $line_hash);
            # Remove empty sets of test data
            if (scalar(keys(%{$testdata->{$testname}})) == 0)
            {
                delete($testdata->{$testname});
                delete($testfncdata->{$testname});
                delete($testbrdata->{$testname});
            }
        }
        # Rename test data to indicate conversion
        foreach $testname (keys(%{$testdata}))
        {
            # Skip testnames which already contain an extension
            if ($testname =~ /,[^,]+$/)
            {
                next;
            }
            # Check for name conflict
            if (defined($testdata->{$testname.",diff"}))
            {
                # Add counts
                ($testdata->{$testname}) = add_counts(
                    $testdata->{$testname},
                    $testdata->{$testname.",diff"});
                delete($testdata->{$testname.",diff"});
                # Add function call counts
                ($testfncdata->{$testname}) = add_fnccount(
                    $testfncdata->{$testname},
                    $testfncdata->{$testname.",diff"});
                delete($testfncdata->{$testname.",diff"});
                # Add branch counts
                ($testbrdata->{$testname}) = combine_brcount(
                    $testbrdata->{$testname},
                    $testbrdata->{$testname.",diff"},
                    $BR_ADD);
                delete($testbrdata->{$testname.",diff"});
            }
            # Move test data to new testname
            $testdata->{$testname.",diff"} = $testdata->{$testname};
            delete($testdata->{$testname});
            # Move function call count data to new testname
            $testfncdata->{$testname.",diff"} =
                $testfncdata->{$testname};
            delete($testfncdata->{$testname});
            # Move branch count data to new testname
            $testbrdata->{$testname.",diff"} =
                $testbrdata->{$testname};
            delete($testbrdata->{$testname});
        }
        # Convert summary of test data
        $sumcount = apply_diff($sumcount, $line_hash);
        # Convert function data
        $funcdata = apply_diff_to_funcdata($funcdata, $line_hash);
        # Convert branch coverage data
        $sumbrcount = apply_diff_to_brcount($sumbrcount, $line_hash);
        # Update found/hit numbers
        # Convert checksum data
        $checkdata = apply_diff($checkdata, $line_hash);
        # Convert function call count data
        adjust_fncdata($funcdata, $testfncdata, $sumfnccount);
        ($f_found, $f_hit) = get_func_found_and_hit($sumfnccount);
        ($br_found, $br_hit) = get_br_found_and_hit($sumbrcount);
        # Update found/hit numbers
        $found = 0;
        $hit = 0;
        foreach (keys(%{$sumcount}))
        {
            $found++;
            if ($sumcount->{$_} > 0)
            {
                $hit++;
            }
        }
        if ($found > 0)
        {
            # Store converted entry
            set_info_entry($entry, $testdata, $sumcount, $funcdata,
                       $checkdata, $testfncdata, $sumfnccount,
                       $testbrdata, $sumbrcount, $found, $hit,
                       $f_found, $f_hit, $br_found, $br_hit);
        }
        else
        {
            # Remove empty data set
            delete($trace_data->{$filename});
        }
        }

    # Convert filenames as well if requested
    if ($convert_filenames)
    {
        convert_paths($trace_data, \%path_conversion_data);
    }

    info("$converted entr".($converted != 1 ? "ies" : "y")." converted, ".
         "$unchanged entr".($unchanged != 1 ? "ies" : "y")." left ".
         "unchanged.\n");

    # Write data
    if ($to_file)
    {
        info("Writing data to $output_filename\n");
        open(INFO_HANDLE, ">", $output_filename)
            or die("ERROR: cannot write to $output_filename!\n");
        @result = write_info_file(*INFO_HANDLE, $trace_data);
        close(*INFO_HANDLE);
    }
    else
    {
        @result = write_info_file(*STDOUT, $trace_data);
    }

    return @result;
}

#
# summary()
#

sub summary()
{
    my $filename;
    my $current;
    my $total;
    my $ln_total_found;
    my $ln_total_hit;
    my $fn_total_found;
    my $fn_total_hit;
    my $br_total_found;
    my $br_total_hit;

    # Read and combine trace files
    foreach $filename (@opt_summary) {
        $current = read_info_file($filename);
        if (!defined($total)) {
            $total = $current;
        } else {
            $total = combine_info_files($total, $current);
        }
    }
    # Calculate coverage data
    foreach $filename (keys(%{$total}))
    {
        my $entry = $total->{$filename};
        my $ln_found;
        my $ln_hit;
        my $fn_found;
        my $fn_hit;
        my $br_found;
        my $br_hit;

        (undef, undef, undef, undef, undef, undef, undef, undef,
            $ln_found, $ln_hit, $fn_found, $fn_hit, $br_found,
            $br_hit) = get_info_entry($entry);

        # Add to totals
        $ln_total_found    += $ln_found;
        $ln_total_hit    += $ln_hit;
        $fn_total_found += $fn_found;
        $fn_total_hit    += $fn_hit;
        $br_total_found += $br_found;
        $br_total_hit    += $br_hit;
    }


    return ($ln_total_found, $ln_total_hit, $fn_total_found, $fn_total_hit,
        $br_total_found, $br_total_hit);
}

#
# system_no_output(mode, parameters)
#
# Call an external program using PARAMETERS while suppressing depending on
# the value of MODE:
#
#   MODE & 1: suppress STDOUT
#   MODE & 2: suppress STDERR
#
# Return 0 on success, non-zero otherwise.
#

sub system_no_output($@)
{
    my $mode = shift;
    my $result;
    local *OLD_STDERR;
    local *OLD_STDOUT;

    # Save old stdout and stderr handles
    ($mode & 1) && open(OLD_STDOUT, ">>&", "STDOUT");
    ($mode & 2) && open(OLD_STDERR, ">>&", "STDERR");

    # Redirect to /dev/null
    ($mode & 1) && open(STDOUT, ">", "/dev/null");
    ($mode & 2) && open(STDERR, ">", "/dev/null");
 
    system(@_);
    $result = $?;

    # Close redirected handles
    ($mode & 1) && close(STDOUT);
    ($mode & 2) && close(STDERR);

    # Restore old handles
    ($mode & 1) && open(STDOUT, ">>&", "OLD_STDOUT");
    ($mode & 2) && open(STDERR, ">>&", "OLD_STDERR");
 
    return $result;
}


#
# read_config(filename)
#
# Read configuration file FILENAME and return a reference to a hash containing
# all valid key=value pairs found.
#

sub read_config($)
{
    my $filename = $_[0];
    my %result;
    my $key;
    my $value;
    local *HANDLE;

    if (!open(HANDLE, "<", $filename))
    {
        warn("WARNING: cannot read configuration file $filename\n");
        return undef;
    }
    while (<HANDLE>)
    {
        chomp;
        # Skip comments
        s/#.*//;
        # Remove leading blanks
        s/^\s+//;
        # Remove trailing blanks
        s/\s+$//;
        next unless length;
        ($key, $value) = split(/\s*=\s*/, $_, 2);
        if (defined($key) && defined($value))
        {
            $result{$key} = $value;
        }
        else
        {
            warn("WARNING: malformed statement in line $. ".
                 "of configuration file $filename\n");
        }
    }
    close(HANDLE);
    return \%result;
}


#
# apply_config(REF)
#
# REF is a reference to a hash containing the following mapping:
#
#   key_string => var_ref
#
# where KEY_STRING is a keyword and VAR_REF is a reference to an associated
# variable. If the global configuration hashes CONFIG or OPT_RC contain a value
# for keyword KEY_STRING, VAR_REF will be assigned the value for that keyword. 
#

sub apply_config($)
{
    my $ref = $_[0];

    foreach (keys(%{$ref}))
    {
        if (defined($opt_rc{$_})) {
            ${$ref->{$_}} = $opt_rc{$_};
        } elsif (defined($config->{$_})) {
            ${$ref->{$_}} = $config->{$_};
        }
    }
}

sub warn_handler($)
{
    my ($msg) = @_;

    temp_cleanup();
    warn("$tool_name: $msg");
}

sub die_handler($)
{
    my ($msg) = @_;

    temp_cleanup();
    die("$tool_name: $msg");
}

sub abort_handler($)
{
    temp_cleanup();
    exit(1);
}

sub temp_cleanup()
{
    if (@temp_dirs) {
        info("Removing temporary directories.\n");
        foreach (@temp_dirs) {
            rmtree($_);
        }
        @temp_dirs = ();
    }
}

sub setup_gkv_sys()
{
    system_no_output(3, "mount", "-t", "debugfs", "nodev",
             "/sys/kernel/debug");
}

sub setup_gkv_proc()
{
    if (system_no_output(3, "modprobe", "gcov_proc")) {
        system_no_output(3, "modprobe", "gcov_prof");
    }
}

sub check_gkv_sys($)
{
    my ($dir) = @_;

    if (-e "$dir/reset") {
        return 1;
    }
    return 0;
}

sub check_gkv_proc($)
{
    my ($dir) = @_;

    if (-e "$dir/vmlinux") {
        return 1;
    }
    return 0;
}

sub setup_gkv()
{
    my $dir;
    my $sys_dir = "/sys/kernel/debug/gcov";
    my $proc_dir = "/proc/gcov";
    my @todo;

    if (!defined($gcov_dir)) {
        info("Auto-detecting gcov kernel support.\n");
        @todo = ( "cs", "cp", "ss", "cs", "sp", "cp" );
    } elsif ($gcov_dir =~ /proc/) {
        info("Checking gcov kernel support at $gcov_dir ".
             "(user-specified).\n");
        @todo = ( "cp", "sp", "cp", "cs", "ss", "cs");
    } else {
        info("Checking gcov kernel support at $gcov_dir ".
             "(user-specified).\n");
        @todo = ( "cs", "ss", "cs", "cp", "sp", "cp", );
    }
    foreach (@todo) {
        if ($_ eq "cs") {
            # Check /sys
            $dir = defined($gcov_dir) ? $gcov_dir : $sys_dir;
            if (check_gkv_sys($dir)) {
                info("Found ".$GKV_NAME[$GKV_SYS]." gcov ".
                     "kernel support at $dir\n");
                return ($GKV_SYS, $dir);
            }
        } elsif ($_ eq "cp") {
            # Check /proc
            $dir = defined($gcov_dir) ? $gcov_dir : $proc_dir;
            if (check_gkv_proc($dir)) {
                info("Found ".$GKV_NAME[$GKV_PROC]." gcov ".
                     "kernel support at $dir\n");
                return ($GKV_PROC, $dir);
            }
        } elsif ($_ eq "ss") {
            # Setup /sys
            setup_gkv_sys();
        } elsif ($_ eq "sp") {
            # Setup /proc
            setup_gkv_proc();
        }
    }
    if (defined($gcov_dir)) {
        die("ERROR: could not find gcov kernel data at $gcov_dir\n");
    } else {
        die("ERROR: no gcov kernel data found\n");
    }
}


#
# get_overall_line(found, hit, name_singular, name_plural)
#
# Return a string containing overall information for the specified
# found/hit data.
#

sub get_overall_line($$$$)
{
    my ($found, $hit, $name_sn, $name_pl) = @_;
    my $name;

    return "no data found" if (!defined($found) || $found == 0);
    $name = ($found == 1) ? $name_sn : $name_pl;

    return rate($hit, $found, "% ($hit of $found $name)");
}


#
# print_overall_rate(ln_do, ln_found, ln_hit, fn_do, fn_found, fn_hit, br_do
#                    br_found, br_hit)
#
# Print overall coverage rates for the specified coverage types.
#

sub print_overall_rate($$$$$$$$$)
{
    my ($ln_do, $ln_found, $ln_hit, $fn_do, $fn_found, $fn_hit,
        $br_do, $br_found, $br_hit) = @_;

    info("Summary coverage rate:\n");
    info("  lines......: %s\n",
         get_overall_line($ln_found, $ln_hit, "line", "lines"))
        if ($ln_do);
    info("  functions..: %s\n",
         get_overall_line($fn_found, $fn_hit, "function", "functions"))
        if ($fn_do);
    info("  branches...: %s\n",
         get_overall_line($br_found, $br_hit, "branch", "branches"))
        if ($br_do);
}


#
# rate(hit, found[, suffix, precision, width])
#
# Return the coverage rate [0..100] for HIT and FOUND values. 0 is only
# returned when HIT is 0. 100 is only returned when HIT equals FOUND.
# PRECISION specifies the precision of the result. SUFFIX defines a
# string that is appended to the result if FOUND is non-zero. Spaces
# are added to the start of the resulting string until it is at least WIDTH
# characters wide.
#

sub rate($$;$$$)
{
        my ($hit, $found, $suffix, $precision, $width) = @_;
        my $rate; 

    # Assign defaults if necessary
        $precision    = 1    if (!defined($precision));
    $suffix        = ""    if (!defined($suffix));
    $width        = 0    if (!defined($width));
        
        return sprintf("%*s", $width, "-") if (!defined($found) || $found == 0);
        $rate = sprintf("%.*f", $precision, $hit * 100 / $found);

    # Adjust rates if necessary
        if ($rate == 0 && $hit > 0) {
        $rate = sprintf("%.*f", $precision, 1 / 10 ** $precision);
        } elsif ($rate == 100 && $hit != $found) {
        $rate = sprintf("%.*f", $precision, 100 - 1 / 10 ** $precision);
    }

    return sprintf("%*s", $width, $rate.$suffix);
}
