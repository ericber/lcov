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
# geninfo
#
#   This script generates .info files from data files as created by code
#   instrumented with gcc's built-in profiling mechanism. Call it with
#   --help and refer to the geninfo man page to get information on usage
#   and available options.
#
#
# Authors:
#   2002-08-23 created by Peter Oberparleiter <Peter.Oberparleiter@de.ibm.com>
#                         IBM Lab Boeblingen
#        based on code by Manoj Iyer <manjo@mail.utexas.edu> and
#                         Megan Bock <mbock@us.ibm.com>
#                         IBM Austin
#   2002-09-05 / Peter Oberparleiter: implemented option that allows file list
#   2003-04-16 / Peter Oberparleiter: modified read_gcov so that it can also
#                parse the new gcov format which is to be introduced in gcc 3.3
#   2003-04-30 / Peter Oberparleiter: made info write to STDERR, not STDOUT
#   2003-07-03 / Peter Oberparleiter: added line checksum support, added
#                --no-checksum
#   2003-09-18 / Nigel Hinds: capture branch coverage data from GCOV
#   2003-12-11 / Laurent Deniel: added --follow option
#                workaround gcov (<= 3.2.x) bug with empty .da files
#   2004-01-03 / Laurent Deniel: Ignore empty .bb files
#   2004-02-16 / Andreas Krebbel: Added support for .gcno/.gcda files and
#                gcov versioning
#   2004-08-09 / Peter Oberparleiter: added configuration file support
#   2008-07-14 / Tom Zoerner: added --function-coverage command line option
#   2008-08-13 / Peter Oberparleiter: modified function coverage
#                implementation (now enabled per default)
#   2014-09-12 / VaL Doroshchuk: ported to Windows

use strict;
use File::Basename;
# FR added use
use File::Find;
use File::Spec::Functions qw /abs2rel rel2abs catdir file_name_is_absolute splitdir
                  splitpath catpath/;
use Getopt::Long;
use Digest::MD5 qw(md5_base64);

use Cwd;

if( $^O eq "msys" )
{
    require File::Spec::Win32;
}

# Constants
our $lcov_version    = 'LCOV version 1.11';
our $lcov_url        = "http://ltp.sourceforge.net/coverage/lcov.php";
# @todo Needs to be changed
our $gcov_tool        = "c://MinGW//bin//gcov.exe";
our $tool_name        = basename($0);

our $GCOV_VERSION_8_0_0	   = 0x80000;
our $GCOV_VERSION_4_7_0    = 0x40700;
our $GCOV_VERSION_3_4_0    = 0x30400;
our $GCOV_VERSION_3_3_0    = 0x30300;
our $GCNO_FUNCTION_TAG    = 0x01000000;
our $GCNO_LINES_TAG    = 0x01450000;
our $GCNO_FILE_MAGIC    = 0x67636e6f;
our $BBG_FILE_MAGIC    = 0x67626267;

# Error classes which users may specify to ignore during processing
our $ERROR_GCOV        = 0;
our $ERROR_SOURCE    = 1;
our $ERROR_GRAPH    = 2;
our %ERROR_ID = (
    "gcov" => $ERROR_GCOV,
    "source" => $ERROR_SOURCE,
    "graph" => $ERROR_GRAPH,
);

our $EXCL_START = "LCOV_EXCL_START";
our $EXCL_STOP = "LCOV_EXCL_STOP";
our $EXCL_LINE = "LCOV_EXCL_LINE";

# Marker to exclude branch coverage but keep function and line coveage
our $EXCL_BR_START = "LCOV_EXCL_BR_START";
our $EXCL_BR_STOP = "LCOV_EXCL_BR_STOP";
our $EXCL_BR_LINE = "LCOV_EXCL_BR_LINE";

# Compatibility mode values
our $COMPAT_VALUE_OFF    = 0;
our $COMPAT_VALUE_ON    = 1;
our $COMPAT_VALUE_AUTO    = 2;

# Compatibility mode value names
our %COMPAT_NAME_TO_VALUE = (
    "off"    => $COMPAT_VALUE_OFF,
    "on"    => $COMPAT_VALUE_ON,
    "auto"    => $COMPAT_VALUE_AUTO,
);

# Compatiblity modes
our $COMPAT_MODE_LIBTOOL    = 1 << 0;
our $COMPAT_MODE_HAMMER        = 1 << 1;
our $COMPAT_MODE_SPLIT_CRC    = 1 << 2;

# Compatibility mode names
our %COMPAT_NAME_TO_MODE = (
    "libtool"    => $COMPAT_MODE_LIBTOOL,
    "hammer"    => $COMPAT_MODE_HAMMER,
    "split_crc"    => $COMPAT_MODE_SPLIT_CRC,
    "android_4_4_0"    => $COMPAT_MODE_SPLIT_CRC,
);

# Map modes to names
our %COMPAT_MODE_TO_NAME = (
    $COMPAT_MODE_LIBTOOL    => "libtool",
    $COMPAT_MODE_HAMMER    => "hammer",
    $COMPAT_MODE_SPLIT_CRC    => "split_crc",
);

# Compatibility mode default values
our %COMPAT_MODE_DEFAULTS = (
    $COMPAT_MODE_LIBTOOL    => $COMPAT_VALUE_ON,
    $COMPAT_MODE_HAMMER    => $COMPAT_VALUE_AUTO,
    $COMPAT_MODE_SPLIT_CRC    => $COMPAT_VALUE_AUTO,
);

# Compatibility mode auto-detection routines
sub compat_hammer_autodetect();
our %COMPAT_MODE_AUTO = (
    $COMPAT_MODE_HAMMER    => \&compat_hammer_autodetect,
    $COMPAT_MODE_SPLIT_CRC    => 1,    # will be done later
);

our $BR_LINE        = 0;
our $BR_BLOCK        = 1;
our $BR_BRANCH        = 2;
our $BR_TAKEN        = 3;
our $BR_VEC_ENTRIES    = 4;
our $BR_VEC_WIDTH    = 32;
our $BR_VEC_MAX        = vec(pack('b*', 1 x $BR_VEC_WIDTH), 0, $BR_VEC_WIDTH);

our $UNNAMED_BLOCK    = -1;

# Prototypes
sub print_usage(*);
sub transform_pattern($);
sub gen_info($);
sub process_dafile($$);
sub match_filename($@);
sub solve_ambiguous_match($$$);
sub split_filename($);
sub solve_relative_path($$);
sub read_gcov_header($);
sub read_gcov_file($);
sub info(@);
sub get_gcov_version();
sub system_no_output($@);
sub read_config($);
sub apply_config($);
sub get_exclusion_data($);
sub apply_exclusion_data($$);
sub process_graphfile($$);
sub filter_fn_name($);
sub warn_handler($);
sub die_handler($);
sub graph_error($$);
sub graph_expect($);
sub graph_read(*$;$$);
sub graph_skip(*$;$);
sub sort_uniq(@);
sub sort_uniq_lex(@);
sub graph_cleanup($);
sub graph_find_base($);
sub graph_from_bb($$$$);
sub graph_add_order($$$);
sub read_bb_word(*;$);
sub read_bb_value(*;$);
sub read_bb_string(*$);
sub read_bb($);
sub read_bbg_word(*;$);
sub read_bbg_value(*;$);
sub read_bbg_string(*);
sub read_bbg_lines_record(*$$$$$);
sub read_bbg($);
sub read_gcno_word(*;$$);
sub read_gcno_value(*$;$$);
sub read_gcno_string(*$);
sub read_gcno_lines_record(*$$$$$$);
sub determine_gcno_split_crc($$$$);
sub read_gcno_function_record(*$$$$$);
sub read_gcno($);
sub get_gcov_capabilities();
sub get_overall_line($$$$);
sub print_overall_rate($$$$$$$$$);
sub br_gvec_len($);
sub br_gvec_get($$);
sub debug($);
sub int_handler();
sub parse_ignore_errors(@);
sub is_external($);
sub compat_name($);
sub parse_compat_modes($);
sub is_compat($);
sub is_compat_auto($);
# FR added wanted subroutine
sub wanted;

# Global variables
our $gcov_version;
our $gcov_version_string;
our $graph_file_extension;
our $data_file_extension;
our @data_directory;
our $test_name = "";
our $quiet;
our $help;
our $output_filename;
our $base_directory;
our $version;
our $follow;
our $checksum;
our $no_checksum;
our $opt_compat_libtool;
our $opt_no_compat_libtool;
our $rc_adjust_src_path;# Regexp specifying parts to remove from source path
our $adjust_src_pattern;
our $adjust_src_replace;
our $adjust_testname;
our $config;        # Configuration file contents
our @ignore_errors;    # List of errors to ignore (parameter)
our @ignore;        # List of errors to ignore (array)
our $initial;
our @include_patterns; # List of source file patterns to include
our @exclude_patterns; # List of source file patterns to exclude
our %excluded_files; # Files excluded due to include/exclude options
our $no_recursion = 0;
our $maxdepth;
our $no_markers = 0;
our $opt_derive_func_data = 0;
our $opt_external = 1;
our $opt_no_external;
our $debug = 0;
our $gcov_caps;
our @gcov_options;
our @internal_dirs;
our $opt_config_file;
our $opt_gcov_all_blocks = 1;
our $opt_compat;
our %opt_rc;
our %compat_value;
our $gcno_split_crc;
our $func_coverage = 1;
our $br_coverage = 1;
our $rc_auto_base = 1;
# FR added temporary file list
our @filelist;

our $cwd = getcwd();
chomp($cwd);


#
# Code entry point
#

# Register handler routine to be called when interrupted
$SIG{"INT"} = \&int_handler;
$SIG{__WARN__} = \&warn_handler;
$SIG{__DIE__} = \&die_handler;

# Prettify version string
$lcov_version =~ s/\$\s*Revision\s*:?\s*(\S+)\s*\$/$1/;

# Set LC_ALL so that gcov output will be in a unified format
$ENV{"LC_ALL"} = "C";

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
        "geninfo_gcov_tool"        => \$gcov_tool,
        "geninfo_adjust_testname"    => \$adjust_testname,
        "geninfo_checksum"        => \$checksum,
        "geninfo_no_checksum"        => \$no_checksum, # deprecated
        "geninfo_compat_libtool"    => \$opt_compat_libtool,
        "geninfo_external"        => \$opt_external,
        "geninfo_gcov_all_blocks"    => \$opt_gcov_all_blocks,
        "geninfo_compat"        => \$opt_compat,
        "geninfo_adjust_src_path"    => \$rc_adjust_src_path,
        "geninfo_auto_base"        => \$rc_auto_base,
        "lcov_function_coverage"    => \$func_coverage,
        "lcov_branch_coverage"        => \$br_coverage,
    });

    # Merge options
    if (defined($no_checksum))
    {
        $checksum = ($no_checksum ? 0 : 1);
        $no_checksum = undef;
    }

    # Check regexp
    if (defined($rc_adjust_src_path)) {
        my ($pattern, $replace) = split(/\s*=>\s*/,
                        $rc_adjust_src_path);
        local $SIG{__DIE__};
        eval '$adjust_src_pattern = qr>'.$pattern.'>;';
        if (!defined($adjust_src_pattern)) {
            my $msg = $@;

            chomp($msg);
            $msg =~ s/at \(eval.*$//;
            warn("WARNING: invalid pattern in ".
                 "geninfo_adjust_src_path: $msg\n");
        } elsif (!defined($replace)) {
            # If no replacement is specified, simply remove pattern
            $adjust_src_replace = "";
        } else {
            $adjust_src_replace = $replace;
        }
    }
}

# Parse command line options
if (!GetOptions("test-name|t=s" => \$test_name,
        "output-filename|o=s" => \$output_filename,
        "checksum" => \$checksum,
        "no-checksum" => \$no_checksum,
        "base-directory|b=s" => \$base_directory,
        "version|v" =>\$version,
        "quiet|q" => \$quiet,
        "help|h|?" => \$help,
        "follow|f" => \$follow,
        "compat-libtool" => \$opt_compat_libtool,
        "no-compat-libtool" => \$opt_no_compat_libtool,
        "gcov-tool=s" => \$gcov_tool,
        "ignore-errors=s" => \@ignore_errors,
        "initial|i" => \$initial,
		"include=s" => \@include_patterns,
		"exclude=s" => \@exclude_patterns,
        "no-recursion" => \$no_recursion,
        "no-markers" => \$no_markers,
        "derive-func-data" => \$opt_derive_func_data,
        "debug" => \$debug,
        "external" => \$opt_external,
        "no-external" => \$opt_no_external,
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

    if (defined($opt_no_compat_libtool))
    {
        $opt_compat_libtool = ($opt_no_compat_libtool ? 0 : 1);
        $opt_no_compat_libtool = undef;
    }

    if (defined($opt_no_external)) {
        $opt_external = 0;
        $opt_no_external = undef;
    }
	if(@include_patterns) {
		# Need perlreg expressions instead of shell pattern
		@include_patterns = map({ transform_pattern($_); } @include_patterns);
	}

	if(@exclude_patterns) {
		# Need perlreg expressions instead of shell pattern
		@exclude_patterns = map({ transform_pattern($_); } @exclude_patterns);
	}
}

@data_directory = @ARGV;

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

# Check gcov tool
if (system_no_output(3, $gcov_tool, "--help") == -1)
{
    die("ERROR: need tool $gcov_tool!\n");
}

($gcov_version, $gcov_version_string) = get_gcov_version();

# Determine gcov options
$gcov_caps = get_gcov_capabilities();
push(@gcov_options, "-b") if ($gcov_caps->{'branch-probabilities'} &&
                  ($br_coverage || $func_coverage));
push(@gcov_options, "-c") if ($gcov_caps->{'branch-counts'} &&
                  $br_coverage);
push(@gcov_options, "-a") if ($gcov_caps->{'all-blocks'} &&
                  $opt_gcov_all_blocks && $br_coverage);
push(@gcov_options, "-p") if ($gcov_caps->{'preserve-paths'});

# Determine compatibility modes
parse_compat_modes($opt_compat);

# Determine which errors the user wants us to ignore
parse_ignore_errors(@ignore_errors);

# Make sure test names only contain valid characters
if ($test_name =~ s/\W/_/g)
{
    warn("WARNING: invalid characters removed from testname!\n");
}

# Adjust test name to include uname output if requested
if ($adjust_testname)
{
    $test_name .= "__".`uname -a`;
    $test_name =~ s/\W/_/g;
}

# Make sure base_directory contains an absolute path specification
if ($base_directory)
{
    $base_directory = solve_relative_path($cwd, $base_directory);
}

# Check for follow option
if ($follow)
{
    $follow = "-follow"
}
else
{
    $follow = "";
}

# Determine checksum mode
if (defined($checksum))
{
    # Normalize to boolean
    $checksum = ($checksum ? 1 : 0);
}
else
{
    # Default is off
    $checksum = 0;
}

# Determine max depth for recursion
if ($no_recursion)
{
    $maxdepth = "-maxdepth 1";
}
else
{
    $maxdepth = "";
}

# Check for directory name
if (!@data_directory)
{
    die("No directory specified\n".
        "Use $tool_name --help to get usage information\n");
}
else
{
    foreach (@data_directory)
    {
        stat($_);
        if (!-r _)
        {
            die("ERROR: cannot read $_!\n");
        }
    }
}

if ($gcov_version < $GCOV_VERSION_3_4_0)
{
    if (is_compat($COMPAT_MODE_HAMMER))
    {
        $data_file_extension = ".da";
        $graph_file_extension = ".bbg";
    }
    else
    {
        $data_file_extension = ".da";
        $graph_file_extension = ".bb";
    }
}
else
{
    $data_file_extension = ".gcda";
    $graph_file_extension = ".gcno";
}

# Check output filename
if (defined($output_filename) && ($output_filename ne "-"))
{
    # Initially create output filename, data is appended
    # for each data file processed
    local *DUMMY_HANDLE;
    open(DUMMY_HANDLE, ">", $output_filename)
        or die("ERROR: cannot create $output_filename!\n");
    close(DUMMY_HANDLE);

    # Make $output_filename an absolute path because we're going
    # to change directories while processing files
    if (!($output_filename =~ /^\/(.*)$/) && !($output_filename =~/[a-zA-Z]:\\*\/*/))
    {
        print ("appending!!!!! $output_filename\n\r");
        $output_filename = $cwd."/".$output_filename;
    }
}

# Build list of directories to identify external files
foreach my $entry(@data_directory, $base_directory) {
    next if (!defined($entry));
    push(@internal_dirs, solve_relative_path($cwd, $entry));
}

# Do something
foreach my $entry (@data_directory) {
    gen_info($entry);
}

if ($initial && $br_coverage) {
    warn("Note: --initial does not generate branch coverage ".
         "data\n");
}
info("Finished .info-file creation\n");

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
Usage: $tool_name [OPTIONS] DIRECTORY

Traverse DIRECTORY and create a .info file for each data file found. Note
that you may specify more than one directory, all of which are then processed
sequentially.

  -h, --help                        Print this help, then exit
  -v, --version                     Print version number, then exit
  -q, --quiet                       Do not print progress messages
  -i, --initial                     Capture initial zero coverage data
  -t, --test-name NAME              Use test case name NAME for resulting data
  -o, --output-filename OUTFILE     Write data only to OUTFILE
  -f, --follow                      Follow links when searching .da/.gcda files
  -b, --base-directory DIR          Use DIR as base directory for relative paths
      --(no-)checksum               Enable (disable) line checksumming
      --(no-)compat-libtool         Enable (disable) libtool compatibility mode
      --gcov-tool TOOL              Specify gcov tool location
      --ignore-errors ERROR         Continue after ERROR (gcov, source, graph)
      --no-recursion                Exclude subdirectories from processing
      --no-markers                  Ignore exclusion markers in source code
      --derive-func-data            Generate function data from line data
      --(no-)external               Include (ignore) data for external files
      --config-file FILENAME        Specify configuration file location
      --rc SETTING=VALUE            Override configuration file setting
      --compat MODE=on|off|auto     Set compat MODE (libtool, hammer, split_crc)
      --include PATTERN             Include files matching PATTERN
      --exclude PATTERN             Exclude files matching PATTERN

For more information see: $lcov_url
END_OF_USAGE
    ;
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
# get_common_prefix(min_dir, filenames)
#
# Return the longest path prefix shared by all filenames. MIN_DIR specifies
# the minimum number of directories that a filename may have after removing
# the prefix.
#

sub get_common_prefix($@)
{
    my ($min_dir, @files) = @_;
    my $file;
    my @prefix;
    my $i;

    foreach $file (@files) {
        my ($v, $d, $f) = splitpath($file);
        my @comp = splitdir($d);

        if (!@prefix) {
            @prefix = @comp;
            next;
        }
        for ($i = 0; $i < scalar(@comp) && $i < scalar(@prefix); $i++) {
            if ($comp[$i] ne $prefix[$i] ||
                ((scalar(@comp) - ($i + 1)) <= $min_dir)) {
                delete(@prefix[$i..scalar(@prefix)]);
                last;
            }
        }
    }

    return catdir(@prefix);
}

#
# gen_info(directory)
#
# Traverse DIRECTORY and create a .info file for each data file found.
# The .info file contains TEST_NAME in the following format:
#
#   TN:<test name>
#
# For each source file name referenced in the data file, there is a section
# containing source code and coverage data:
#
#   SF:<absolute path to the source file>
#   FN:<line number of function start>,<function name> for each function
#   DA:<line number>,<execution count> for each instrumented line
#   LH:<number of lines with an execution count> greater than 0
#   LF:<number of instrumented lines>
#
# Sections are separated by:
#
#   end_of_record
#
# In addition to the main source code file there are sections for each
# #included file containing executable code. Note that the absolute path
# of a source file is generated by interpreting the contents of the respective
# graph file. Relative filenames are prefixed with the directory in which the
# graph file is found. Note also that symbolic links to the graph file will be
# resolved so that the actual file path is used instead of the path to a link.
# This approach is necessary for the mechanism to work with the /proc/gcov
# files.
#
# Die on error.
#

# FR filter for Find method to
# search for files with gcda extension in all subfolders
sub wanted
{
    if (-f $_)
    {
        if ($_ =~ m/\.gcda$/)
        {
            push @filelist, $File::Find::name;
        }
    }
}

sub gen_info($)
{
    my $directory = $_[0];
    my @file_list;
    my $file;
    my $prefix;
    my $type;
    my $ext;

    if ($initial) {
        $type = "graph";
        $ext = $graph_file_extension;
    } else {
        $type = "data";
        $ext = $data_file_extension;
    }

    if (-d $directory)
    {
        info("Scanning $directory for $ext files ...\n");

        # FR rem @file_list = 'find "$directory" $maxdepth $follow -name \\*$ext -type f 2>/dev/null';
        # FR added find instead of linux find
        find(\&wanted, $directory);

        @file_list = @filelist;
        chomp(@file_list);
        if (!@file_list) {
            warn("WARNING: no $ext files found in $directory - ".
                 "skipping!\n");
            return;
        }
        $prefix = get_common_prefix(1, @file_list);
        info("Found %d %s files in %s\n", $#file_list+1, $type,
             $directory);
    }
    else
    {
        @file_list = ($directory);
        $prefix = "";
    }

    # Process all files in list
    foreach $file (@file_list) {
        # Process file
        if ($initial) {
            process_graphfile($file, $prefix);
        } else {
            process_dafile($file, $prefix);
        }
	}
	# Report whether files were excluded.
	if (%excluded_files) {
		info("Excluded data for %d files due to include/exclude options\n",
			 scalar keys %excluded_files);
    }
}


#
# derive_data(contentdata, funcdata, bbdata)
#
# Calculate function coverage data by combining line coverage data and the
# list of lines belonging to a function.
#
# contentdata: [ instr1, count1, source1, instr2, count2, source2, ... ]
# instr<n>: Instrumentation flag for line n
# count<n>: Execution count for line n
# source<n>: Source code for line n
#
# funcdata: [ count1, func1, count2, func2, ... ]
# count<n>: Execution count for function number n
# func<n>: Function name for function number n
#
# bbdata: function_name -> [ line1, line2, ... ]
# line<n>: Line number belonging to the corresponding function
#

sub derive_data($$$)
{
    my ($contentdata, $funcdata, $bbdata) = @_;
    my @gcov_content = @{$contentdata};
    my @gcov_functions = @{$funcdata};
    my %fn_count;
    my %ln_fn;
    my $line;
    my $maxline;
    my %fn_name;
    my $fn;
    my $count;

    if (!defined($bbdata)) {
        return @gcov_functions;
    }

    # First add existing function data
    while (@gcov_functions) {
        $count = shift(@gcov_functions);
        $fn = shift(@gcov_functions);

        $fn_count{$fn} = $count;
    }

    # Convert line coverage data to function data
    foreach $fn (keys(%{$bbdata})) {
        my $line_data = $bbdata->{$fn};
        my $line;
        my $fninstr = 0;

        if ($fn eq "") {
            next;
        }
        # Find the lowest line count for this function
        $count = 0;
        foreach $line (@$line_data) {
            my $linstr = $gcov_content[ ( $line - 1 ) * 3 + 0 ];
            my $lcount = $gcov_content[ ( $line - 1 ) * 3 + 1 ];

            next if (!$linstr);
            $fninstr = 1;
            if (($lcount > 0) &&
                (($count == 0) || ($lcount < $count))) {
                $count = $lcount;
            }
        }
        next if (!$fninstr);
        $fn_count{$fn} = $count;
    }


    # Check if we got data for all functions
    foreach $fn (keys(%fn_name)) {
        if ($fn eq "") {
            next;
        }
        if (defined($fn_count{$fn})) {
            next;
        }
        warn("WARNING: no derived data found for function $fn\n");
    }

    # Convert hash to list in @gcov_functions format
    foreach $fn (sort(keys(%fn_count))) {
        push(@gcov_functions, $fn_count{$fn}, $fn);
    }

    return @gcov_functions;
}

#
# get_filenames(directory, pattern)
#
# Return a list of filenames found in directory which match the specified
# pattern.
#
# Die on error.
#

sub get_filenames($$)
{
    my ($dirname, $pattern) = @_;
    my @result;
    my $directory;
    local *DIR;

    opendir(DIR, $dirname) or
        die("ERROR: cannot read directory $dirname\n");
    while ($directory = readdir(DIR)) {
        push(@result, $directory) if ($directory =~ /$pattern/);
    }
    closedir(DIR);

    return @result;
}

#
# process_dafile(da_filename, dir)
#
# Create a .info file for a single data file.
#
# Die on error.
#

sub process_dafile($$)
{
    my ($file, $dir) = @_;
    my $da_filename;    # Name of data file to process
    my $da_dir;        # Directory of data file
    my $source_dir;        # Directory of source file
    my $da_basename;    # data filename without ".da/.gcda" extension
    my $bb_filename;    # Name of respective graph file
    my $bb_basename;    # Basename of the original graph file
    my $graph;        # Contents of graph file
    my $instr;        # Contents of graph file part 2
    my $gcov_error;        # Error code of gcov tool
    my $object_dir;        # Directory containing all object files
    my $source_filename;    # Name of a source code file
    my $gcov_file;        # Name of a .gcov file
    my @gcov_content;    # Content of a .gcov file
    my $gcov_branches;    # Branch content of a .gcov file
    my @gcov_functions;    # Function calls of a .gcov file
    my @gcov_list;        # List of generated .gcov files
    my $line_number;    # Line number count
    my $lines_hit;        # Number of instrumented lines hit
    my $lines_found;    # Number of instrumented lines found
    my $funcs_hit;        # Number of instrumented functions hit
    my $funcs_found;    # Number of instrumented functions found
    my $br_hit;
    my $br_found;
    my $source;        # gcov source header information
    my $object;        # gcov object header information
    my @matches;        # List of absolute paths matching filename
    my $base_dir;        # Base directory for current file
    my @tmp_links;        # Temporary links to be cleaned up
    my @result;
    my $index;
    my $da_renamed;        # If data file is to be renamed
    local *INFO_HANDLE;

    info("Processing %s\n", abs2rel($file, $dir));
    # Get path to data file in absolute and normalized form (begins with /,
    # contains no more ../ or ./)
    $da_filename = solve_relative_path($cwd, $file);

    # Get directory and basename of data file
    ($da_dir, $da_basename) = split_filename($da_filename);

    $source_dir = $da_dir;
    if (is_compat($COMPAT_MODE_LIBTOOL)) {
        # Avoid files from .libs dirs
        $source_dir =~ s/\.libs$//;
    }

    if (-z $da_filename)
    {
        $da_renamed = 1;
    }
    else
    {
        $da_renamed = 0;
    }

    # Construct base_dir for current file
    if ($base_directory)
    {
        $base_dir = $base_directory;
    }
    else
    {
        $base_dir = $source_dir;
    }

    # Check for writable $base_dir (gcov will try to write files there)
    stat($base_dir);
    if (!-w _)
    {
        die("ERROR: cannot write to directory $base_dir!\n");
    }

    # Construct name of graph file
    $bb_basename = $da_basename.$graph_file_extension;
    $bb_filename = "$da_dir/$bb_basename";

    # Find out the real location of graph file in case we're just looking at
    # a link
    while (readlink($bb_filename))
    {
        my $last_dir = dirname($bb_filename);

        $bb_filename = readlink($bb_filename);
        $bb_filename = solve_relative_path($last_dir, $bb_filename);
    }

    # Ignore empty graph file (e.g. source file with no statement)
    if (-z $bb_filename)
    {
        warn("WARNING: empty $bb_filename (skipped)\n");
        return;
    }

    # Read contents of graph file into hash. We need it later to find out
    # the absolute path to each .gcov file created as well as for
    # information about functions and their source code positions.
    if ($gcov_version < $GCOV_VERSION_3_4_0)
    {
        if (is_compat($COMPAT_MODE_HAMMER))
        {
            ($instr, $graph) = read_bbg($bb_filename);
        }
        else
        {
            ($instr, $graph) = read_bb($bb_filename);
        }
    }
    else
    {
        ($instr, $graph) = read_gcno($bb_filename);
    }

    # Try to find base directory automatically if requested by user
    if ($rc_auto_base) {
        $base_dir = find_base_from_graph($base_dir, $instr, $graph);
    }

    ($instr, $graph) = adjust_graph_filenames($base_dir, $instr, $graph);

    # Set $object_dir to real location of object files. This may differ
    # from $da_dir if the graph file is just a link to the "real" object
    # file location.
    $object_dir = dirname($bb_filename);

    # Is the data file in a different directory? (this happens e.g. with
    # the gcov-kernel patch)
    if ($object_dir ne $da_dir)
    {
        # Need to create link to data file in $object_dir
        system("ln", "-s", $da_filename,
               "$object_dir/$da_basename$data_file_extension")
            and die ("ERROR: cannot create link $object_dir/".
                 "$da_basename$data_file_extension!\n");
        push(@tmp_links,
             "$object_dir/$da_basename$data_file_extension");
        # Need to create link to graph file if basename of link
        # and file are different (CONFIG_MODVERSION compat)
        if ((basename($bb_filename) ne $bb_basename) &&
            (! -e "$object_dir/$bb_basename")) {
            symlink($bb_filename, "$object_dir/$bb_basename") or
                warn("WARNING: cannot create link ".
                     "$object_dir/$bb_basename\n");
            push(@tmp_links, "$object_dir/$bb_basename");
        }
    }

    # Change to directory containing data files and apply GCOV
    debug("chdir($base_dir)\n");
        chdir($base_dir);

    if ($da_renamed)
    {
        # Need to rename empty data file to workaround
            # gcov <= 3.2.x bug (Abort)
        system_no_output(3, "mv", "$da_filename", "$da_filename.ori")
            and die ("ERROR: cannot rename $da_filename\n");
    }

    # Execute gcov command and suppress standard output
    $gcov_error = system_no_output(1, $gcov_tool, $da_filename,
                       "-o", $object_dir, @gcov_options);

    if ($da_renamed)
    {
        system_no_output(3, "mv", "$da_filename.ori", "$da_filename")
            and die ("ERROR: cannot rename $da_filename.ori");
    }

    # Clean up temporary links
    foreach (@tmp_links) {
        unlink($_);
    }

    if ($gcov_error)
    {
        if ($ignore[$ERROR_GCOV])
        {
            warn("WARNING: GCOV failed for $da_filename!\n");
            return;
        }
        die("ERROR: GCOV failed for $da_filename!\n");
    }

    # Collect data from resulting .gcov files and create .info file
    @gcov_list = get_filenames('.', '\.gcov$');

    # Check for files
    if (!@gcov_list)
    {
        warn("WARNING: gcov did not create any files for ".
             "$da_filename!\n");
    }

    # Check whether we're writing to a single file
    if ($output_filename)
    {
        if ($output_filename eq "-")
        {
            *INFO_HANDLE = *STDOUT;
        }
        else
        {
            # Append to output file
            open(INFO_HANDLE, ">>", $output_filename)
                or die("ERROR: cannot write to ".
                       "$output_filename!\n");
        }
    }
    else
    {
        # Open .info file for output
        open(INFO_HANDLE, ">", "$da_filename.info")
            or die("ERROR: cannot create $da_filename.info!\n");
    }

    # Write test name
    printf(INFO_HANDLE "TN:%s\n", $test_name);

    # Traverse the list of generated .gcov files and combine them into a
    # single .info file
    foreach $gcov_file (sort(@gcov_list))
    {
        my $i;
        my $num;

        # Skip gcov file for gcc built-in code
        next if ($gcov_file eq "<built-in>.gcov");

        ($source, $object) = read_gcov_header($gcov_file);

        if (!defined($source)) {
            # Derive source file name from gcov file name if
            # header format could not be parsed
            $source = $gcov_file;
            $source =~ s/\.gcov$//;
        }

        $source = solve_relative_path($base_dir, $source);

        if (defined($adjust_src_pattern)) {
            # Apply transformation as specified by user
            $source =~ s/$adjust_src_pattern/$adjust_src_replace/g;
        }

        # gcov will happily create output even if there's no source code
        # available - this interferes with checksum creation so we need
        # to pull the emergency brake here.
        if (! -r $source && $checksum)
        {
            if ($ignore[$ERROR_SOURCE])
            {
                warn("WARNING: could not read source file ".
                     "$source\n");
                next;
            }
            die("ERROR: could not read source file $source\n");
        }

        @matches = match_filename($source, keys(%{$instr}));

        # Skip files that are not mentioned in the graph file
        if (!@matches)
        {
            warn("WARNING: cannot find an entry for ".$gcov_file.
                 " in $graph_file_extension file, skipping ".
                 "file!\n");
            unlink($gcov_file);
            next;
        }

        # Read in contents of gcov file
        @result = read_gcov_file($gcov_file);
        if (!defined($result[0])) {
            warn("WARNING: skipping unreadable file ".
                 $gcov_file."\n");
            unlink($gcov_file);
            next;
        }
        @gcov_content = @{$result[0]};
        $gcov_branches = $result[1];
        @gcov_functions = @{$result[2]};

        # Skip empty files
        if (!@gcov_content)
        {
            warn("WARNING: skipping empty file ".$gcov_file."\n");
            unlink($gcov_file);
            next;
        }

        if (scalar(@matches) == 1)
        {
            # Just one match
            $source_filename = $matches[0];
        }
        else
        {
            # Try to solve the ambiguity
            $source_filename = solve_ambiguous_match($gcov_file,
                        \@matches, \@gcov_content);
		}

		if (@include_patterns)
		{
			my $keep = 0;

			foreach my $pattern (@include_patterns)
			{
				$keep ||= ($source_filename =~ (/^$pattern$/));
			}

			if (!$keep)
			{
				$excluded_files{$source_filename} = ();
				unlink($gcov_file);
				next;
			}
		}

		if (@exclude_patterns)
		{
			my $exclude = 0;

			foreach my $pattern (@exclude_patterns)
			{
				$exclude ||= ($source_filename =~ (/^$pattern$/));
			}

			if ($exclude)
			{
				$excluded_files{$source_filename} = ();
				unlink($gcov_file);
				next;
			}
        }

        # Skip external files if requested
        if (!$opt_external) {
            if (is_external($source_filename)) {
                info("  ignoring data for external file ".
                     "$source_filename\n");
                unlink($gcov_file);
                next;
            }
        }

        # Write absolute path of source file
        my $sf_absolute_path = rel2abs($source_filename);
        printf(INFO_HANDLE "SF:%s\n", $sf_absolute_path);

        # If requested, derive function coverage data from
        # line coverage data of the first line of a function
        if ($opt_derive_func_data) {
            @gcov_functions =
                derive_data(\@gcov_content, \@gcov_functions,
                        $graph->{$source_filename});
        }

        # Write function-related information
        if (defined($graph->{$source_filename}))
        {
            my $fn_data = $graph->{$source_filename};
            my $fn;

            foreach $fn (sort
                {$fn_data->{$a}->[0] <=> $fn_data->{$b}->[0]}
                keys(%{$fn_data})) {
                my $ln_data = $fn_data->{$fn};
                my $line = $ln_data->[0];

                # Skip empty function
                if ($fn eq "") {
                    next;
                }
                # Remove excluded functions
                if (!$no_markers) {
                    my $gfn;
                    my $found = 0;

                    foreach $gfn (@gcov_functions) {
                        if ($gfn eq $fn) {
                            $found = 1;
                            last;
                        }
                    }
                    if (!$found) {
                        next;
                    }
                }

                # Normalize function name
                $fn = filter_fn_name($fn);

                print(INFO_HANDLE "FN:$line,$fn\n");
            }
        }

        #--
        #-- FNDA: <call-count>, <function-name>
        #-- FNF: overall count of functions
        #-- FNH: overall count of functions with non-zero call count
        #--
        $funcs_found = 0;
        $funcs_hit = 0;
        while (@gcov_functions)
        {
            my $count = shift(@gcov_functions);
            my $fn = shift(@gcov_functions);

            $fn = filter_fn_name($fn);
            printf(INFO_HANDLE "FNDA:$count,$fn\n");
            $funcs_found++;
            $funcs_hit++ if ($count > 0);
        }
        if ($funcs_found > 0) {
            printf(INFO_HANDLE "FNF:%s\n", $funcs_found);
            printf(INFO_HANDLE "FNH:%s\n", $funcs_hit);
        }

        # Write coverage information for each instrumented branch:
        #
        #   BRDA:<line number>,<block number>,<branch number>,<taken>
        #
        # where 'taken' is the number of times the branch was taken
        # or '-' if the block to which the branch belongs was never
        # executed
        $br_found = 0;
        $br_hit = 0;
        $num = br_gvec_len($gcov_branches);
        for ($i = 0; $i < $num; $i++) {
            my ($line, $block, $branch, $taken) =
                br_gvec_get($gcov_branches, $i);

            $block = $BR_VEC_MAX if ($block < 0);
            print(INFO_HANDLE "BRDA:$line,$block,$branch,$taken\n");
            $br_found++;
            $br_hit++ if ($taken ne '-' && $taken > 0);
        }
        if ($br_found > 0) {
            printf(INFO_HANDLE "BRF:%s\n", $br_found);
            printf(INFO_HANDLE "BRH:%s\n", $br_hit);
        }

        # Reset line counters
        $line_number = 0;
        $lines_found = 0;
        $lines_hit = 0;

        # Write coverage information for each instrumented line
        # Note: @gcov_content contains a list of (flag, count, source)
        # tuple for each source code line
        while (@gcov_content)
        {
            $line_number++;

            # Check for instrumented line
            if ($gcov_content[0])
            {
                $lines_found++;
                printf(INFO_HANDLE "DA:".$line_number.",".
                       $gcov_content[1].($checksum ?
                       ",". md5_base64($gcov_content[2]) : "").
                       "\n");

                # Increase $lines_hit in case of an execution
                # count>0
                if ($gcov_content[1] > 0) { $lines_hit++; }
            }

            # Remove already processed data from array
            splice(@gcov_content,0,3);
        }

        # Write line statistics and section separator
        printf(INFO_HANDLE "LF:%s\n", $lines_found);
        printf(INFO_HANDLE "LH:%s\n", $lines_hit);
        print(INFO_HANDLE "end_of_record\n");

        # Remove .gcov file after processing
        unlink($gcov_file);
    }

    if (!($output_filename && ($output_filename eq "-")))
    {
        close(INFO_HANDLE);
    }

    # Change back to initial directory
    chdir($cwd);
}


#
# solve_relative_path(path, dir)
#
# Solve relative path components of DIR which, if not absolute, resides in PATH.
#

sub solve_relative_path($$)
{
    my $path = $_[0];
    my $dir = $_[1];
    my $volume;
    my $directories;
    my $filename;
    my @dirs;            # holds path elements
    my $result;

    # Convert from Windows path to msys path
    if( $^O eq "msys" )
    {
        # search for a windows drive letter at the beginning
        ($volume, $directories, $filename) = File::Spec::Win32->splitpath( $dir );
        if( $volume ne '' )
        {
            my $uppercase_volume;
            # transform c/d\../e/f\g to Windows style c\d\..\e\f\g
            $dir = File::Spec::Win32->canonpath( $dir );
            # use Win32 module to retrieve path components
            # $uppercase_volume is not used any further
            ( $uppercase_volume, $directories, $filename ) = File::Spec::Win32->splitpath( $dir );
            @dirs = File::Spec::Win32->splitdir( $directories );

            # prepend volume, since in msys C: is always mounted to /c
            $volume =~ s|^([a-zA-Z]+):|/\L$1\E|;
            unshift( @dirs, $volume );

            # transform to Unix style '/' path
            $directories = File::Spec->catdir( @dirs );
            $dir = File::Spec->catpath( '', $directories, $filename );
        } else {
            # eliminate '\' path separators
            $dir = File::Spec->canonpath( $dir );
        }
    }

    $result = $dir;
    # Prepend path if not absolute
    #if ($dir =~ /^[^\/]/)
    # starts with .. or .
    if ($dir =~ /^\.+/)
    {
        #$result = "$path/$result";
    }

    # Remove //
    $result =~ s/\/\//\//g;

    # Remove .
    $result =~ s/\/\.\//\//g;
    $result =~ s/\/\.$/\//g;

    # Remove trailing /
    $result =~ s/\/$//g;

    # Solve ..
    while ($result =~ s/\/[^\/]+\/\.\.\//\//)
    {
    }

    # Remove preceding ..
    $result =~ s/^\/\.\.\//\//g;

    return $result;
}


#
# match_filename(gcov_filename, list)
#
# Return a list of those entries of LIST which match the relative filename
# GCOV_FILENAME.
#

sub match_filename($@)
{
    my ($filename, @list) = @_;
    my ($vol, $dir, $file) = splitpath($filename);
    my @comp = splitdir($dir);
    my $comps = scalar(@comp);
    my $entry;
    my @result;

entry:
    foreach $entry (@list) {
        my ($evol, $edir, $efile) = splitpath($entry);
        my @ecomp;
        my $ecomps;
        my $i;

        # Filename component must match
        if ($efile ne $file) {
            next;
        }
        # Check directory components last to first for match
        @ecomp = splitdir($edir);
        $ecomps = scalar(@ecomp);
        if ($ecomps < $comps) {
            next;
        }
        for ($i = 0; $i < $comps; $i++) {
            if ($comp[$comps - $i - 1] ne
                $ecomp[$ecomps - $i - 1]) {
                next entry;
            }
        }
        push(@result, $entry),
    }

    return @result;
}

#
# solve_ambiguous_match(rel_filename, matches_ref, gcov_content_ref)
#
# Try to solve ambiguous matches of mapping (gcov file) -> (source code) file
# by comparing source code provided in the GCOV file with that of the files
# in MATCHES. REL_FILENAME identifies the relative filename of the gcov
# file.
#
# Return the one real match or die if there is none.
#

sub solve_ambiguous_match($$$)
{
    my $rel_name = $_[0];
    my $matches = $_[1];
    my $content = $_[2];
    my $filename;
    my $index;
    my $no_match;
    local *SOURCE;

    # Check the list of matches
    foreach $filename (@$matches)
    {

        # Compare file contents
        open(SOURCE, "<", $filename)
            or die("ERROR: cannot read $filename!\n");

        $no_match = 0;
        for ($index = 2; <SOURCE>; $index += 3)
        {
            chomp;

            # Also remove CR from line-end
            s/\015$//;

            if ($_ ne @$content[$index])
            {
                $no_match = 1;
                last;
            }
        }

        close(SOURCE);

        if (!$no_match)
        {
            info("Solved source file ambiguity for $rel_name\n");
            return $filename;
        }
    }

    die("ERROR: could not match gcov data for $rel_name!\n");
}


#
# split_filename(filename)
#
# Return (path, filename, extension) for a given FILENAME.
#

sub split_filename($)
{
    my @path_components = split('/', $_[0]);
    my @file_components = split('\.', pop(@path_components));
    my $extension = pop(@file_components);

    return (join("/",@path_components), join(".",@file_components),
        $extension);
}


#
# read_gcov_header(gcov_filename)
#
# Parse file GCOV_FILENAME and return a list containing the following
# information:
#
#   (source, object)
#
# where:
#
# source: complete relative path of the source code file (gcc >= 3.3 only)
# object: name of associated graph file
#
# Die on error.
#

sub read_gcov_header($)
{
    my $source;
    my $object;
    local *INPUT;

    if (!open(INPUT, "<", $_[0]))
    {
        if ($ignore_errors[$ERROR_GCOV])
        {
            warn("WARNING: cannot read $_[0]!\n");
            return (undef,undef);
        }
        die("ERROR: cannot read $_[0]!\n");
    }

    while (<INPUT>)
    {
        chomp($_);

        # Also remove CR from line-end
        s/\015$//;

        if (/^\s+-:\s+0:Source:(.*)$/)
        {
            # Source: header entry
            $source = $1;
        }
        elsif (/^\s+-:\s+0:Object:(.*)$/)
        {
            # Object: header entry
            $object = $1;
        }
        else
        {
            last;
        }
    }

    close(INPUT);

    return ($source, $object);
}


#
# br_gvec_len(vector)
#
# Return the number of entries in the branch coverage vector.
#

sub br_gvec_len($)
{
    my ($vec) = @_;

    return 0 if (!defined($vec));
    return (length($vec) * 8 / $BR_VEC_WIDTH) / $BR_VEC_ENTRIES;
}


#
# br_gvec_get(vector, number)
#
# Return an entry from the branch coverage vector.
#

sub br_gvec_get($$)
{
    my ($vec, $num) = @_;
    my $line;
    my $block;
    my $branch;
    my $taken;
    my $offset = $num * $BR_VEC_ENTRIES;

    # Retrieve data from vector
    $line    = vec($vec, $offset + $BR_LINE, $BR_VEC_WIDTH);
    $block    = vec($vec, $offset + $BR_BLOCK, $BR_VEC_WIDTH);
    $block = -1 if ($block == $BR_VEC_MAX);
    $branch = vec($vec, $offset + $BR_BRANCH, $BR_VEC_WIDTH);
    $taken    = vec($vec, $offset + $BR_TAKEN, $BR_VEC_WIDTH);

    # Decode taken value from an integer
    if ($taken == 0) {
        $taken = "-";
    } else {
        $taken--;
    }

    return ($line, $block, $branch, $taken);
}


#
# br_gvec_push(vector, line, block, branch, taken)
#
# Add an entry to the branch coverage vector.
#

sub br_gvec_push($$$$$)
{
    my ($vec, $line, $block, $branch, $taken) = @_;
    my $offset;

    $vec = "" if (!defined($vec));
    $offset = br_gvec_len($vec) * $BR_VEC_ENTRIES;
    $block = $BR_VEC_MAX if $block < 0;

    # Encode taken value into an integer
    if ($taken eq "-") {
        $taken = 0;
    } else {
        $taken++;
    }

    # Add to vector
    vec($vec, $offset + $BR_LINE, $BR_VEC_WIDTH) = $line;
    vec($vec, $offset + $BR_BLOCK, $BR_VEC_WIDTH) = $block;
    vec($vec, $offset + $BR_BRANCH, $BR_VEC_WIDTH) = $branch;
    vec($vec, $offset + $BR_TAKEN, $BR_VEC_WIDTH) = $taken;

    return $vec;
}


#
# read_gcov_file(gcov_filename)
#
# Parse file GCOV_FILENAME (.gcov file format) and return the list:
# (reference to gcov_content, reference to gcov_branch, reference to gcov_func)
#
# gcov_content is a list of 3 elements
# (flag, count, source) for each source code line:
#
# $result[($line_number-1)*3+0] = instrumentation flag for line $line_number
# $result[($line_number-1)*3+1] = execution count for line $line_number
# $result[($line_number-1)*3+2] = source code text for line $line_number
#
# gcov_branch is a vector of 4 4-byte long elements for each branch:
# line number, block number, branch number, count + 1 or 0
#
# gcov_func is a list of 2 elements
# (number of calls, function name) for each function
#
# Die on error.
#

sub read_gcov_file($)
{
    my $filename = $_[0];
    my @result = ();
    my $branches = "";
    my @functions = ();
    my $number;
    my $exclude_flag = 0;
    my $exclude_line = 0;
    my $exclude_br_flag = 0;
    my $exclude_branch = 0;
    my $last_block = $UNNAMED_BLOCK;
    my $last_line = 0;
    local *INPUT;

    if (!open(INPUT, "<", $filename)) {
        if ($ignore_errors[$ERROR_GCOV])
        {
            warn("WARNING: cannot read $filename!\n");
            return (undef, undef, undef);
        }
        die("ERROR: cannot read $filename!\n");
    }

    if ($gcov_version < $GCOV_VERSION_3_3_0)
    {
        # Expect gcov format as used in gcc < 3.3
        while (<INPUT>)
        {
            chomp($_);

            # Also remove CR from line-end
            s/\015$//;

            if (/^branch\s+(\d+)\s+taken\s+=\s+(\d+)/) {
                next if (!$br_coverage);
                next if ($exclude_line);
                next if ($exclude_branch);
                $branches = br_gvec_push($branches, $last_line,
                        $last_block, $1, $2);
            } elsif (/^branch\s+(\d+)\s+never\s+executed/) {
                next if (!$br_coverage);
                next if ($exclude_line);
                next if ($exclude_branch);
                $branches = br_gvec_push($branches, $last_line,
                        $last_block, $1, '-');
            }
            elsif (/^call/ || /^function/)
            {
                # Function call return data
            }
            else
            {
                $last_line++;
                # Check for exclusion markers
                if (!$no_markers) {
                    if (/$EXCL_STOP/) {
                        $exclude_flag = 0;
                    } elsif (/$EXCL_START/) {
                        $exclude_flag = 1;
                    }
                    if (/$EXCL_LINE/ || $exclude_flag) {
                        $exclude_line = 1;
                    } else {
                        $exclude_line = 0;
                    }
                }
                # Check for exclusion markers (branch exclude)
                if (!$no_markers) {
                    if (/$EXCL_BR_STOP/) {
                        $exclude_br_flag = 0;
                    } elsif (/$EXCL_BR_START/) {
                        $exclude_br_flag = 1;
                    }
                    if (/$EXCL_BR_LINE/ || $exclude_br_flag) {
                        $exclude_branch = 1;
                    } else {
                        $exclude_branch = 0;
                    }
                }
                # Source code execution data
                if (/^\t\t(.*)$/)
                {
                    # Uninstrumented line
                    push(@result, 0);
                    push(@result, 0);
                    push(@result, $1);
                    next;
                }
                $number = (split(" ",substr($_, 0, 16)))[0];

                # Check for zero count which is indicated
                # by ######
                if ($number eq "######") { $number = 0;    }

                if ($exclude_line) {
                    # Register uninstrumented line instead
                    push(@result, 0);
                    push(@result, 0);
                } else {
                    push(@result, 1);
                    push(@result, $number);
                }
                push(@result, substr($_, 16));
            }
        }
    }
    else
    {
        # Expect gcov format as used in gcc >= 3.3
        while (<INPUT>)
        {
            chomp($_);

            # Also remove CR from line-end
            s/\015$//;

            if (/^\s*(\d+|\$+):\s*(\d+)-block\s+(\d+)\s*$/) {
                # Block information - used to group related
                # branches
                $last_line = $2;
                $last_block = $3;
            } elsif (/^branch\s+(\d+)\s+taken\s+(\d+)/) {
                next if (!$br_coverage);
                next if ($exclude_line);
                next if ($exclude_branch);
                $branches = br_gvec_push($branches, $last_line,
                        $last_block, $1, $2);
            } elsif (/^branch\s+(\d+)\s+never\s+executed/) {
                next if (!$br_coverage);
                next if ($exclude_line);
                next if ($exclude_branch);
                $branches = br_gvec_push($branches, $last_line,
                        $last_block, $1, '-');
            }
            elsif (/^function\s+(.+)\s+called\s+(\d+)\s+/)
            {
                next if (!$func_coverage);
                if ($exclude_line) {
                    next;
                }
                push(@functions, $2, $1);
            }
            elsif (/^call/)
            {
                # Function call return data
            }
            elsif (/^\s*([^:]+):\s*([^:]+):(.*)$/)
            {
                my ($count, $line, $code) = ($1, $2, $3);

                # Skip instance-specific counts
				next if ($line == $last_line);

                $last_line = $line;
                $last_block = $UNNAMED_BLOCK;
                # Check for exclusion markers
                if (!$no_markers) {
                    if (/$EXCL_STOP/) {
                        $exclude_flag = 0;
                    } elsif (/$EXCL_START/) {
                        $exclude_flag = 1;
                    }
                    if (/$EXCL_LINE/ || $exclude_flag) {
                        $exclude_line = 1;
                    } else {
                        $exclude_line = 0;
                    }
                }
                # Check for exclusion markers (branch exclude)
                if (!$no_markers) {
                    if (/$EXCL_BR_STOP/) {
                        $exclude_br_flag = 0;
                    } elsif (/$EXCL_BR_START/) {
                        $exclude_br_flag = 1;
                    }
                    if (/$EXCL_BR_LINE/ || $exclude_br_flag) {
                        $exclude_branch = 1;
                    } else {
                        $exclude_branch = 0;
                    }
                }

                # Strip unexecuted basic block marker
				$count =~ s/\*$//;

                # <exec count>:<line number>:<source code>
                if ($line eq "0")
                {
                    # Extra data
                }
                elsif ($count eq "-")
                {
                    # Uninstrumented line
                    push(@result, 0);
                    push(@result, 0);
                    push(@result, $code);
                }
                else
                {
                    if ($exclude_line) {
                        push(@result, 0);
                        push(@result, 0);
                    } else {
                        # Check for zero count
                        if ($count =~ /^[#=]/) {
                            $count = 0;
                        }
                        push(@result, 1);
                        push(@result, $count);
                    }
                    push(@result, $code);
                }
            }
        }
    }

    close(INPUT);
    if ($exclude_flag || $exclude_br_flag) {
        warn("WARNING: unterminated exclusion section in $filename\n");
    }
    return(\@result, $branches, \@functions);
}


#
# Get the GCOV tool version. Return an integer number which represents the
# GCOV version. Version numbers can be compared using standard integer
# operations.
#

sub get_gcov_version()
{
    local *HANDLE;
    my $version_string;
    my $result;

    open(GCOV_PIPE, "-|", "$gcov_tool --version")
        or die("ERROR: cannot retrieve gcov version!\n");
    $version_string = <GCOV_PIPE>;
    # LLVM gcov keeps version information on the second line.
    # For example, gcov --version yields:
    # LLVM (http://llvm.org/):
    #   LLVM version 3.4svn
    $version_string = <GCOV_PIPE> if ($version_string =~ /LLVM/);
    close(GCOV_PIPE);

    # Remove version information in parenthesis to cope with the following:
    # - gcov (GCC) 4.4.7 20120313 (Red Hat 4.4.7-3)
    # - gcov (crosstool-NG 1.18.0) 4.7.2
    $version_string =~ s/\([^\)]*\)//g;

    $result = 0;
    if ($version_string =~ /(\d+)\.(\d+)(\.(\d+))?/)
    {
        if (defined($4))
        {
            info("Found gcov version: $1.$2.$4\n");
            $result = $1 << 16 | $2 << 8 | $4;
        }
        else
        {
            info("Found gcov version: $1.$2\n");
            $result = $1 << 16 | $2 << 8;
        }
    }
    if ($version_string =~ /LLVM/)
    {
        # Map LLVM versions to the version of GCC gcov which
        # they emulate
        if ($result >= 0x030400)
        {
            info("Found LLVM gcov version 3.4, which emulates gcov version 4.2\n");
            $result = 0x040200;
        }
        else
        {
            warn("This version of LLVM's gcov is unknown.  Assuming it emulates GCC gcov version 4.2.\n");
            $result = 0x040200;
        }
    }
    return ($result, $version_string);
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
        if (defined($output_filename) && ($output_filename eq "-"))
        {
            # Don't interfere with the .info output to STDOUT
            printf(STDERR @_);
        }
        else
        {
            printf(@_);
        }
    }
}


#
# int_handler()
#
# Called when the script was interrupted by an INT signal (e.g. CTRl-C)
#

sub int_handler()
{
    if ($cwd) { chdir($cwd); }
    info("Aborted.\n");
    exit(1);
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

    debug("system(".join(' ', @_).")\n");
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


#
# get_exclusion_data(filename)
#
# Scan specified source code file for exclusion markers and return
#   linenumber -> 1
# for all lines which should be excluded.
#

sub get_exclusion_data($)
{
    my ($filename) = @_;
    my %list;
    my $flag = 0;
    local *HANDLE;

    if (!open(HANDLE, "<", $filename)) {
        warn("WARNING: could not open $filename\n");
        return undef;
    }
    while (<HANDLE>) {
        if (/$EXCL_STOP/) {
            $flag = 0;
        } elsif (/$EXCL_START/) {
            $flag = 1;
        }
        if (/$EXCL_LINE/ || $flag) {
            $list{$.} = 1;
        }
    }
    close(HANDLE);

    if ($flag) {
        warn("WARNING: unterminated exclusion section in $filename\n");
    }

    return \%list;
}


#
# apply_exclusion_data(instr, graph)
#
# Remove lines from instr and graph data structures which are marked
# for exclusion in the source code file.
#
# Return adjusted (instr, graph).
#
# graph         : file name -> function data
# function data : function name -> line data
# line data     : [ line1, line2, ... ]
#
# instr     : filename -> line data
# line data : [ line1, line2, ... ]
#

sub apply_exclusion_data($$)
{
    my ($instr, $graph) = @_;
    my $filename;
    my %excl_data;
    my $excl_read_failed = 0;

    # Collect exclusion marker data
    foreach $filename (sort_uniq_lex(keys(%{$graph}), keys(%{$instr}))) {
        my $excl = get_exclusion_data($filename);

        # Skip and note if file could not be read
        if (!defined($excl)) {
            $excl_read_failed = 1;
            next;
        }

        # Add to collection if there are markers
        $excl_data{$filename} = $excl if (keys(%{$excl}) > 0);
    }

    # Warn if not all source files could be read
    if ($excl_read_failed) {
        warn("WARNING: some exclusion markers may be ignored\n");
    }

    # Skip if no markers were found
    return ($instr, $graph) if (keys(%excl_data) == 0);

    # Apply exclusion marker data to graph
    foreach $filename (keys(%excl_data)) {
        my $function_data = $graph->{$filename};
        my $excl = $excl_data{$filename};
        my $function;

        next if (!defined($function_data));

        foreach $function (keys(%{$function_data})) {
            my $line_data = $function_data->{$function};
            my $line;
            my @new_data;

            # To be consistent with exclusion parser in non-initial
            # case we need to remove a function if the first line
            # was excluded
            if ($excl->{$line_data->[0]}) {
                delete($function_data->{$function});
                next;
            }
            # Copy only lines which are not excluded
            foreach $line (@{$line_data}) {
                push(@new_data, $line) if (!$excl->{$line});
            }

            # Store modified list
            if (scalar(@new_data) > 0) {
                $function_data->{$function} = \@new_data;
            } else {
                # All of this function was excluded
                delete($function_data->{$function});
            }
        }

        # Check if all functions of this file were excluded
        if (keys(%{$function_data}) == 0) {
            delete($graph->{$filename});
        }
    }

    # Apply exclusion marker data to instr
    foreach $filename (keys(%excl_data)) {
        my $line_data = $instr->{$filename};
        my $excl = $excl_data{$filename};
        my $line;
        my @new_data;

        next if (!defined($line_data));

        # Copy only lines which are not excluded
        foreach $line (@{$line_data}) {
            push(@new_data, $line) if (!$excl->{$line});
        }

        # Store modified list
        $instr->{$filename} = \@new_data;
    }

    return ($instr, $graph);
}


sub process_graphfile($$)
{
    my ($file, $dir) = @_;
    my $graph_filename = $file;
    my $graph_dir;
    my $graph_basename;
    my $source_dir;
    my $base_dir;
    my $graph;
    my $instr;
    my $filename;
    local *INFO_HANDLE;

    info("Processing %s\n", abs2rel($file, $dir));

    # Get path to data file in absolute and normalized form (begins with /,
    # contains no more ../ or ./)
    $graph_filename = solve_relative_path($cwd, $graph_filename);

    # Get directory and basename of data file
    ($graph_dir, $graph_basename) = split_filename($graph_filename);

    $source_dir = $graph_dir;
    if (is_compat($COMPAT_MODE_LIBTOOL)) {
        # Avoid files from .libs dirs
        $source_dir =~ s/\.libs$//;
    }

    # Construct base_dir for current file
    if ($base_directory)
    {
        $base_dir = $base_directory;
    }
    else
    {
        $base_dir = $source_dir;
    }

    if ($gcov_version < $GCOV_VERSION_3_4_0)
    {
        if (is_compat($COMPAT_MODE_HAMMER))
        {
            ($instr, $graph) = read_bbg($graph_filename);
        }
        else
        {
            ($instr, $graph) = read_bb($graph_filename);
        }
    }
    else
    {
        ($instr, $graph) = read_gcno($graph_filename);
    }

    # Try to find base directory automatically if requested by user
    if ($rc_auto_base) {
        $base_dir = find_base_from_graph($base_dir, $instr, $graph);
    }

    ($instr, $graph) = adjust_graph_filenames($base_dir, $instr, $graph);

    if (!$no_markers) {
        # Apply exclusion marker data to graph file data
        ($instr, $graph) = apply_exclusion_data($instr, $graph);
    }

    # Check whether we're writing to a single file
    if ($output_filename)
    {
        if ($output_filename eq "-")
        {
            *INFO_HANDLE = *STDOUT;
        }
        else
        {
            # Append to output file
            open(INFO_HANDLE, ">>", $output_filename)
                or die("ERROR: cannot write to ".
                       "$output_filename!\n");
        }
    }
    else
    {
        # Open .info file for output
        open(INFO_HANDLE, ">", "$graph_filename.info")
            or die("ERROR: cannot create $graph_filename.info!\n");
    }

    # Write test name
    printf(INFO_HANDLE "TN:%s\n", $test_name);
    foreach $filename (sort(keys(%{$instr})))
    {
        my $funcdata = $graph->{$filename};
        my $line;
        my $linedata;

        # Skip external files if requested
        if (!$opt_external) {
            if (is_external($filename)) {
                info("  ignoring data for external file ".
                     "$filename\n");
                next;
            }
        }

        print(INFO_HANDLE "SF:$filename\n");

        if (defined($funcdata) && $func_coverage) {
            my @functions = sort {$funcdata->{$a}->[0] <=>
                          $funcdata->{$b}->[0]}
                         keys(%{$funcdata});
            my $func;

            # Gather list of instrumented lines and functions
            foreach $func (@functions) {
                $linedata = $funcdata->{$func};

                # Print function name and starting line
                print(INFO_HANDLE "FN:".$linedata->[0].
                      ",".filter_fn_name($func)."\n");
            }
            # Print zero function coverage data
            foreach $func (@functions) {
                print(INFO_HANDLE "FNDA:0,".
                      filter_fn_name($func)."\n");
            }
            # Print function summary
            print(INFO_HANDLE "FNF:".scalar(@functions)."\n");
            print(INFO_HANDLE "FNH:0\n");
        }
        # Print zero line coverage data
        foreach $line (@{$instr->{$filename}}) {
            print(INFO_HANDLE "DA:$line,0\n");
        }
        # Print line summary
        print(INFO_HANDLE "LF:".scalar(@{$instr->{$filename}})."\n");
        print(INFO_HANDLE "LH:0\n");

        print(INFO_HANDLE "end_of_record\n");
    }
    if (!($output_filename && ($output_filename eq "-")))
    {
        close(INFO_HANDLE);
    }
}

sub filter_fn_name($)
{
    my ($fn) = @_;

    # Remove characters used internally as function name delimiters
    $fn =~ s/[,=]/_/g;

    return $fn;
}

sub warn_handler($)
{
    my ($msg) = @_;

    warn("$tool_name: $msg");
}

sub die_handler($)
{
    my ($msg) = @_;

    die("$tool_name: $msg");
}


#
# graph_error(filename, message)
#
# Print message about error in graph file. If ignore_graph_error is set, return.
# Otherwise abort.
#

sub graph_error($$)
{
    my ($filename, $msg) = @_;

    if ($ignore[$ERROR_GRAPH]) {
        warn("WARNING: $filename: $msg - skipping\n");
        return;
    }
    die("ERROR: $filename: $msg\n");
}

#
# graph_expect(description)
#
# If debug is set to a non-zero value, print the specified description of what
# is expected to be read next from the graph file.
#

sub graph_expect($)
{
    my ($msg) = @_;

    if (!$debug || !defined($msg)) {
        return;
    }

    print(STDERR "DEBUG: expecting $msg\n");
}

#
# graph_read(handle, bytes[, description, peek])
#
# Read and return the specified number of bytes from handle. Return undef
# if the number of bytes could not be read. If PEEK is non-zero, reset
# file position after read.
#

sub graph_read(*$;$$)
{
    my ($handle, $length, $desc, $peek) = @_;
    my $data;
    my $result;
    my $pos;

    graph_expect($desc);
    if ($peek) {
        $pos = tell($handle);
        if ($pos == -1) {
            warn("Could not get current file position: $!\n");
            return undef;
        }
    }
    $result = read($handle, $data, $length);
    if ($debug) {
        my $op = $peek ? "peek" : "read";
        my $ascii = "";
        my $hex = "";
        my $i;

        print(STDERR "DEBUG: $op($length)=$result: ");
        for ($i = 0; $i < length($data); $i++) {
            my $c = substr($data, $i, 1);;
            my $n = ord($c);

            $hex .= sprintf("%02x ", $n);
            if ($n >= 32 && $n <= 127) {
                $ascii .= $c;
            } else {
                $ascii .= ".";
            }
        }
        print(STDERR "$hex |$ascii|");
        print(STDERR "\n");
    }
    if ($peek) {
        if (!seek($handle, $pos, 0)) {
            warn("Could not set file position: $!\n");
            return undef;
        }
    }
    if ($result != $length) {
        return undef;
    }
    return $data;
}

#
# graph_skip(handle, bytes[, description])
#
# Read and discard the specified number of bytes from handle. Return non-zero
# if bytes could be read, zero otherwise.
#

sub graph_skip(*$;$)
{
    my ($handle, $length, $desc) = @_;

    if (defined(graph_read($handle, $length, $desc))) {
        return 1;
    }
    return 0;
}

#
# sort_uniq(list)
#
# Return list in numerically ascending order and without duplicate entries.
#

sub sort_uniq(@)
{
    my (@list) = @_;
    my %hash;

    foreach (@list) {
        $hash{$_} = 1;
    }
    return sort { $a <=> $b } keys(%hash);
}

#
# sort_uniq_lex(list)
#
# Return list in lexically ascending order and without duplicate entries.
#

sub sort_uniq_lex(@)
{
    my (@list) = @_;
    my %hash;

    foreach (@list) {
        $hash{$_} = 1;
    }
    return sort keys(%hash);
}

#
# parent_dir(dir)
#
# Return parent directory for DIR. DIR must not contain relative path
# components.
#

sub parent_dir($)
{
    my ($dir) = @_;
    my ($v, $d, $f) = splitpath($dir, 1);
    my @dirs = splitdir($d);

    pop(@dirs);

    return catpath($v, catdir(@dirs), $f);
}

#
# find_base_from_graph(base_dir, instr, graph)
#
# Try to determine the base directory of the graph file specified by INSTR
# and GRAPH. The base directory is the base for all relative filenames in
# the graph file. It is defined by the current working directory at time
# of compiling the source file.
#
# This function implements a heuristic which relies on the following
# assumptions:
# - all files used for compilation are still present at their location
# - the base directory is either BASE_DIR or one of its parent directories
# - files by the same name are not present in multiple parent directories
#

sub find_base_from_graph($$$)
{
    my ($base_dir, $instr, $graph) = @_;
    my $old_base;
    my $best_miss;
    my $best_base;
    my %rel_files;

    # Determine list of relative paths
    foreach my $filename (keys(%{$instr}), keys(%{$graph})) {
        next if (file_name_is_absolute($filename));

        $rel_files{$filename} = 1;
    }

    # Early exit if there are no relative paths
    return $base_dir if (!%rel_files);

    do {
        my $miss = 0;

        foreach my $filename (keys(%rel_files)) {
            if (!-e solve_relative_path($base_dir, $filename)) {
                $miss++;
            }
        }

        debug("base_dir=$base_dir miss=$miss\n");

        # Exit if we find an exact match with no misses
        return $base_dir if ($miss == 0);

        # No exact match, aim for the one with the least source file
        # misses
        if (!defined($best_base) || $miss < $best_miss) {
            $best_base = $base_dir;
            $best_miss = $miss;
        }

        # Repeat until there's no more parent directory
        $old_base = $base_dir;
        $base_dir = parent_dir($base_dir);
    } while ($old_base ne $base_dir);

    return $best_base;
}

#
# adjust_graph_filenames(base_dir, instr, graph)
#
# Make relative paths in INSTR and GRAPH absolute and apply
# geninfo_adjust_src_path setting to graph file data.
#

sub adjust_graph_filenames($$$)
{
    my ($base_dir, $instr, $graph) = @_;

    foreach my $filename (keys(%{$instr})) {
        my $old_filename = $filename;

        # Convert to absolute canonical form
        $filename = solve_relative_path($base_dir, $filename);

        # Apply adjustment
        if (defined($adjust_src_pattern)) {
            $filename =~ s/$adjust_src_pattern/$adjust_src_replace/g;
        }

        if ($filename ne $old_filename) {
            $instr->{$filename} = delete($instr->{$old_filename});
        }
    }

    foreach my $filename (keys(%{$graph})) {
        my $old_filename = $filename;

        # Make absolute
        # Convert to absolute canonical form
        $filename = solve_relative_path($base_dir, $filename);

        # Apply adjustment
        if (defined($adjust_src_pattern)) {
            $filename =~ s/$adjust_src_pattern/$adjust_src_replace/g;
        }

        if ($filename ne $old_filename) {
            $graph->{$filename} = delete($graph->{$old_filename});
        }
    }

    return ($instr, $graph);
}

#
# graph_cleanup(graph)
#
# Remove entries for functions with no lines. Remove duplicate line numbers.
# Sort list of line numbers numerically ascending.
#

sub graph_cleanup($)
{
    my ($graph) = @_;
    my $filename;

    foreach $filename (keys(%{$graph})) {
        my $per_file = $graph->{$filename};
        my $function;

        foreach $function (keys(%{$per_file})) {
            my $lines = $per_file->{$function};

            if (scalar(@$lines) == 0) {
                # Remove empty function
                delete($per_file->{$function});
                next;
            }
            # Normalize list
            $per_file->{$function} = [ sort_uniq(@$lines) ];
        }
        if (scalar(keys(%{$per_file})) == 0) {
            # Remove empty file
            delete($graph->{$filename});
        }
    }
}

#
# graph_find_base(bb)
#
# Try to identify the filename which is the base source file for the
# specified bb data.
#

sub graph_find_base($)
{
    my ($bb) = @_;
    my %file_count;
    my $basefile;
    my $file;
    my $func;
    my $filedata;
    my $count;
    my $num;

    # Identify base name for this bb data.
    foreach $func (keys(%{$bb})) {
        $filedata = $bb->{$func};

        foreach $file (keys(%{$filedata})) {
            $count = $file_count{$file};

            # Count file occurrence
            $file_count{$file} = defined($count) ? $count + 1 : 1;
        }
    }
    $count = 0;
    $num = 0;
    foreach $file (keys(%file_count)) {
        if ($file_count{$file} > $count) {
            # The file that contains code for the most functions
            # is likely the base file
            $count = $file_count{$file};
            $num = 1;
            $basefile = $file;
        } elsif ($file_count{$file} == $count) {
            # If more than one file could be the basefile, we
            # don't have a basefile
            $basefile = undef;
        }
    }

    return $basefile;
}

#
# graph_from_bb(bb, fileorder, bb_filename)
#
# Convert data from bb to the graph format and list of instrumented lines.
# Returns (instr, graph).
#
# bb         : function name -> file data
#            : undef -> file order
# file data  : filename -> line data
# line data  : [ line1, line2, ... ]
#
# file order : function name -> [ filename1, filename2, ... ]
#
# graph         : file name -> function data
# function data : function name -> line data
# line data     : [ line1, line2, ... ]
#
# instr     : filename -> line data
# line data : [ line1, line2, ... ]
#

sub graph_from_bb($$$$)
{
	my ($bb, $fileorder, $bb_filename, $fileorder_first) = @_;
	my $graph = {};
	my $instr = {};
	my $basefile;
	my $file;
	my $func;
	my $filedata;
	my $linedata;
	my $order;

    $basefile = graph_find_base($bb);
    # Create graph structure
    foreach $func (keys(%{$bb})) {
        $filedata = $bb->{$func};
        $order = $fileorder->{$func};

		# Account for lines in functions
		if (defined($basefile) && defined($filedata->{$basefile}) &&
		    !$fileorder_first) {
			# If the basefile contributes to this function,
			# account this function to the basefile.
			$graph->{$basefile}->{$func} = $filedata->{$basefile};
		} else {
			# If the basefile does not contribute to this function,
			# account this function to the first file contributing
			# lines.
			$graph->{$order->[0]}->{$func} =
				$filedata->{$order->[0]};
		}

        foreach $file (keys(%{$filedata})) {
            # Account for instrumented lines
            $linedata = $filedata->{$file};
            push(@{$instr->{$file}}, @$linedata);
        }
    }
    # Clean up array of instrumented lines
    foreach $file (keys(%{$instr})) {
        $instr->{$file} = [ sort_uniq(@{$instr->{$file}}) ];
    }

    return ($instr, $graph);
}

#
# graph_add_order(fileorder, function, filename)
#
# Add an entry for filename to the fileorder data set for function.
#

sub graph_add_order($$$)
{
    my ($fileorder, $function, $filename) = @_;
    my $item;
    my $list;

    $list = $fileorder->{$function};
    foreach $item (@$list) {
        if ($item eq $filename) {
            return;
        }
    }
    push(@$list, $filename);
    $fileorder->{$function} = $list;
}

#
# read_bb_word(handle[, description])
#
# Read and return a word in .bb format from handle.
#

sub read_bb_word(*;$)
{
    my ($handle, $desc) = @_;

    return graph_read($handle, 4, $desc);
}

#
# read_bb_value(handle[, description])
#
# Read a word in .bb format from handle and return the word and its integer
# value.
#

sub read_bb_value(*;$)
{
    my ($handle, $desc) = @_;
    my $word;

    $word = read_bb_word($handle, $desc);
    return undef if (!defined($word));

    return ($word, unpack("V", $word));
}

#
# read_bb_string(handle, delimiter)
#
# Read and return a string in .bb format from handle up to the specified
# delimiter value.
#

sub read_bb_string(*$)
{
    my ($handle, $delimiter) = @_;
    my $word;
    my $value;
    my $string = "";

    graph_expect("string");
    do {
        ($word, $value) = read_bb_value($handle, "string or delimiter");
        return undef if (!defined($value));
        if ($value != $delimiter) {
            $string .= $word;
        }
    } while ($value != $delimiter);
    $string =~ s/\0//g;

    return $string;
}

#
# read_bb(filename)
#
# Read the contents of the specified .bb file and return (instr, graph), where:
#
#   instr     : filename -> line data
#   line data : [ line1, line2, ... ]
#
#   graph     :     filename -> file_data
#   file_data : function name -> line_data
#   line_data : [ line1, line2, ... ]
#
# See the gcov info pages of gcc 2.95 for a description of the .bb file format.
#

sub read_bb($)
{
    my ($bb_filename) = @_;
    my $minus_one = 0x80000001;
    my $minus_two = 0x80000002;
    my $value;
    my $filename;
    my $function;
    my $bb = {};
    my $fileorder = {};
    my $instr;
    my $graph;
    local *HANDLE;

    open(HANDLE, "<", $bb_filename) or goto open_error;
    binmode(HANDLE);
    while (!eof(HANDLE)) {
        $value = read_bb_value(*HANDLE, "data word");
        goto incomplete if (!defined($value));
        if ($value == $minus_one) {
            # Source file name
            graph_expect("filename");
            $filename = read_bb_string(*HANDLE, $minus_one);
            goto incomplete if (!defined($filename));
        } elsif ($value == $minus_two) {
            # Function name
            graph_expect("function name");
            $function = read_bb_string(*HANDLE, $minus_two);
            goto incomplete if (!defined($function));
        } elsif ($value > 0) {
            # Line number
            if (!defined($filename) || !defined($function)) {
                warn("WARNING: unassigned line number ".
                     "$value\n");
                next;
            }
            push(@{$bb->{$function}->{$filename}}, $value);
            graph_add_order($fileorder, $function, $filename);
        }
    }
    close(HANDLE);
	($instr, $graph) = graph_from_bb($bb, $fileorder, $bb_filename, 0);
    graph_cleanup($graph);

    return ($instr, $graph);

open_error:
    graph_error($bb_filename, "could not open file");
    return undef;
incomplete:
    graph_error($bb_filename, "reached unexpected end of file");
    return undef;
}

#
# read_bbg_word(handle[, description])
#
# Read and return a word in .bbg format.
#

sub read_bbg_word(*;$)
{
    my ($handle, $desc) = @_;

    return graph_read($handle, 4, $desc);
}

#
# read_bbg_value(handle[, description])
#
# Read a word in .bbg format from handle and return its integer value.
#

sub read_bbg_value(*;$)
{
    my ($handle, $desc) = @_;
    my $word;

    $word = read_bbg_word($handle, $desc);
    return undef if (!defined($word));

    return unpack("N", $word);
}

#
# read_bbg_string(handle)
#
# Read and return a string in .bbg format.
#

sub read_bbg_string(*)
{
    my ($handle, $desc) = @_;
    my $length;
    my $string;

    graph_expect("string");
    # Read string length
    $length = read_bbg_value($handle, "string length");
    return undef if (!defined($length));
    if ($length == 0) {
        return "";
    }
    # Read string
    $string = graph_read($handle, $length, "string");
    return undef if (!defined($string));
    # Skip padding
    graph_skip($handle, 4 - $length % 4, "string padding") or return undef;

    return $string;
}

#
# read_bbg_lines_record(handle, bbg_filename, bb, fileorder, filename,
#                       function)
#
# Read a bbg format lines record from handle and add the relevant data to
# bb and fileorder. Return filename on success, undef on error.
#

sub read_bbg_lines_record(*$$$$$)
{
    my ($handle, $bbg_filename, $bb, $fileorder, $filename, $function) = @_;
    my $string;
    my $lineno;

    graph_expect("lines record");
    # Skip basic block index
    graph_skip($handle, 4, "basic block index") or return undef;
    while (1) {
        # Read line number
        $lineno = read_bbg_value($handle, "line number");
        return undef if (!defined($lineno));
        if ($lineno == 0) {
            # Got a marker for a new filename
            graph_expect("filename");
            $string = read_bbg_string($handle);
            return undef if (!defined($string));
            # Check for end of record
            if ($string eq "") {
                return $filename;
            }
            $filename = $string;
            if (!exists($bb->{$function}->{$filename})) {
                $bb->{$function}->{$filename} = [];
            }
            next;
        }
        # Got an actual line number
        if (!defined($filename)) {
            warn("WARNING: unassigned line number in ".
                 "$bbg_filename\n");
            next;
        }
        push(@{$bb->{$function}->{$filename}}, $lineno);
        graph_add_order($fileorder, $function, $filename);
    }
}

#
# read_bbg(filename)
#
# Read the contents of the specified .bbg file and return the following mapping:
#   graph:     filename -> file_data
#   file_data: function name -> line_data
#   line_data: [ line1, line2, ... ]
#
# See the gcov-io.h file in the SLES 9 gcc 3.3.3 source code for a description
# of the .bbg format.
#

sub read_bbg($)
{
    my ($bbg_filename) = @_;
    my $file_magic = 0x67626267;
    my $tag_function = 0x01000000;
    my $tag_lines = 0x01450000;
    my $word;
    my $tag;
    my $length;
    my $function;
    my $filename;
    my $bb = {};
    my $fileorder = {};
    my $instr;
    my $graph;
    local *HANDLE;

    open(HANDLE, "<", $bbg_filename) or goto open_error;
    binmode(HANDLE);
    # Read magic
    $word = read_bbg_value(*HANDLE, "file magic");
    goto incomplete if (!defined($word));
    # Check magic
    if ($word != $file_magic) {
        goto magic_error;
    }
    # Skip version
    graph_skip(*HANDLE, 4, "version") or goto incomplete;
    while (!eof(HANDLE)) {
        # Read record tag
        $tag = read_bbg_value(*HANDLE, "record tag");
        goto incomplete if (!defined($tag));
        # Read record length
        $length = read_bbg_value(*HANDLE, "record length");
        goto incomplete if (!defined($tag));
        if ($tag == $tag_function) {
            graph_expect("function record");
            # Read function name
            graph_expect("function name");
            $function = read_bbg_string(*HANDLE);
            goto incomplete if (!defined($function));
            $filename = undef;
            # Skip function checksum
            graph_skip(*HANDLE, 4, "function checksum")
                or goto incomplete;
        } elsif ($tag == $tag_lines) {
            # Read lines record
            $filename = read_bbg_lines_record(HANDLE, $bbg_filename,
                      $bb, $fileorder, $filename,
                      $function);
            goto incomplete if (!defined($filename));
        } else {
            # Skip record contents
            graph_skip(*HANDLE, $length, "unhandled record")
                or goto incomplete;
        }
    }
    close(HANDLE);
	($instr, $graph) = graph_from_bb($bb, $fileorder, $bbg_filename, 0);
    graph_cleanup($graph);

    return ($instr, $graph);

open_error:
    graph_error($bbg_filename, "could not open file");
    return undef;
incomplete:
    graph_error($bbg_filename, "reached unexpected end of file");
    return undef;
magic_error:
    graph_error($bbg_filename, "found unrecognized bbg file magic");
    return undef;
}

#
# read_gcno_word(handle[, description, peek])
#
# Read and return a word in .gcno format.
#

sub read_gcno_word(*;$$)
{
    my ($handle, $desc, $peek) = @_;

    return graph_read($handle, 4, $desc, $peek);
}

#
# read_gcno_value(handle, big_endian[, description, peek])
#
# Read a word in .gcno format from handle and return its integer value
# according to the specified endianness. If PEEK is non-zero, reset file
# position after read.
#

sub read_gcno_value(*$;$$)
{
    my ($handle, $big_endian, $desc, $peek) = @_;
    my $word;
    my $pos;

    $word = read_gcno_word($handle, $desc, $peek);
    return undef if (!defined($word));
    if ($big_endian) {
        return unpack("N", $word);
    } else {
        return unpack("V", $word);
    }
}

#
# read_gcno_string(handle, big_endian)
#
# Read and return a string in .gcno format.
#

sub read_gcno_string(*$)
{
    my ($handle, $big_endian) = @_;
    my $length;
    my $string;

    graph_expect("string");
    # Read string length
    $length = read_gcno_value($handle, $big_endian, "string length");
    return undef if (!defined($length));
    if ($length == 0) {
        return "";
    }
    $length *= 4;
    # Read string
    $string = graph_read($handle, $length, "string and padding");
    return undef if (!defined($string));
    $string =~ s/\0//g;

    return $string;
}

#
# read_gcno_lines_record(handle, gcno_filename, bb, fileorder, filename,
#                        function, big_endian)
#
# Read a gcno format lines record from handle and add the relevant data to
# bb and fileorder. Return filename on success, undef on error.
#

sub read_gcno_lines_record(*$$$$$$)
{
    my ($handle, $gcno_filename, $bb, $fileorder, $filename, $function,
        $big_endian) = @_;
    my $string;
    my $lineno;

    graph_expect("lines record");
    # Skip basic block index
    graph_skip($handle, 4, "basic block index") or return undef;
    while (1) {
        # Read line number
        $lineno = read_gcno_value($handle, $big_endian, "line number");
        return undef if (!defined($lineno));
        if ($lineno == 0) {
            # Got a marker for a new filename
            graph_expect("filename");
            $string = read_gcno_string($handle, $big_endian);
            return undef if (!defined($string));
            # Check for end of record
            if ($string eq "") {
                return $filename;
            }
            $filename = $string;
            if (!exists($bb->{$function}->{$filename})) {
                $bb->{$function}->{$filename} = [];
            }
            next;
        }
        # Got an actual line number
        if (!defined($filename)) {
            warn("WARNING: unassigned line number in ".
                 "$gcno_filename\n");
            next;
        }
        # Add to list
        push(@{$bb->{$function}->{$filename}}, $lineno);
        graph_add_order($fileorder, $function, $filename);
    }
}

#
# determine_gcno_split_crc(handle, big_endian, rec_length, version)
#
# Determine if HANDLE refers to a .gcno file with a split checksum function
# record format. Return non-zero in case of split checksum format, zero
# otherwise, undef in case of read error.
#

sub determine_gcno_split_crc($$$$)
{
	my ($handle, $big_endian, $rec_length, $version) = @_;
	my $strlen;
	my $overlong_string;

	return 1 if ($version >= $GCOV_VERSION_4_7_0);
	return 1 if (is_compat($COMPAT_MODE_SPLIT_CRC));

    # Heuristic:
    # Decide format based on contents of next word in record:
    # - pre-gcc 4.7
    #   This is the function name length / 4 which should be
    #   less than the remaining record length
    # - gcc 4.7
    #   This is a checksum, likely with high-order bits set,
    #   resulting in a large number
    $strlen = read_gcno_value($handle, $big_endian, undef, 1);
    return undef if (!defined($strlen));
    $overlong_string = 1 if ($strlen * 4 >= $rec_length - 12);

    if ($overlong_string) {
        if (is_compat_auto($COMPAT_MODE_SPLIT_CRC)) {
            info("Auto-detected compatibility mode for split ".
                 "checksum .gcno file format\n");

            return 1;
        } else {
            # Sanity check
            warn("Found overlong string in function record: ".
                 "try '--compat split_crc'\n");
        }
    }

    return 0;
}

#
# read_gcno_function_record(handle, graph, big_endian, rec_length, version)
#
# Read a gcno format function record from handle and add the relevant data
# to graph. Return (filename, function, artificial) on success, undef on error.
#

sub read_gcno_function_record(*$$$$$)
{
	my ($handle, $bb, $fileorder, $big_endian, $rec_length, $version) = @_;
	my $filename;
	my $function;
	my $lineno;
	my $lines;
	my $artificial;

    graph_expect("function record");
    # Skip ident and checksum
    graph_skip($handle, 8, "function ident and checksum") or return undef;
    # Determine if this is a function record with split checksums
    if (!defined($gcno_split_crc)) {
        $gcno_split_crc = determine_gcno_split_crc($handle, $big_endian,
							   $rec_length,
							   $version);
        return undef if (!defined($gcno_split_crc));
    }
    # Skip cfg checksum word in case of split checksums
    graph_skip($handle, 4, "function cfg checksum") if ($gcno_split_crc);
    # Read function name
    graph_expect("function name");
    $function = read_gcno_string($handle, $big_endian);
    return undef if (!defined($function));
    if ($version >= $GCOV_VERSION_8_0_0) {
		$artificial = read_gcno_value($handle, $big_endian,
					      "compiler-generated entity flag");
		return undef if (!defined($artificial));
	}
    # Read filename
    graph_expect("filename");
    $filename = read_gcno_string($handle, $big_endian);
    return undef if (!defined($filename));
    # Read first line number
    $lineno = read_gcno_value($handle, $big_endian, "initial line number");
    return undef if (!defined($lineno));
    # Skip column and ending line number
	if ($version >= $GCOV_VERSION_8_0_0) {
		graph_skip($handle, 4, "column number") or return undef;
		graph_skip($handle, 4, "ending line number") or return undef;
	}
    # Add to list
    push(@{$bb->{$function}->{$filename}}, $lineno);
    graph_add_order($fileorder, $function, $filename);

	return ($filename, $function, $artificial);
}

#
# map_gcno_version
#
# Map version number as found in .gcno files to the format used in geninfo.
#

sub map_gcno_version($)
{
	my ($version) = @_;
	my ($a, $b, $c);
	my ($major, $minor);

	$a = $version >> 24;
	$b = $version >> 16 & 0xff;
	$c = $version >> 8 & 0xff;

	if ($a < ord('A')) {
		$major = $a - ord('0');
		$minor = ($b - ord('0')) * 10 + $c - ord('0');
	} else {
		$major = ($a - ord('A')) * 10 + $b - ord('0');
		$minor = $c - ord('0');
	}

	return $major << 16 | $minor << 8;
}

sub remove_fn_from_hash($$)
{
	my ($hash, $fns) = @_;

	foreach my $fn (@$fns) {
		delete($hash->{$fn});
	}
}

#
# read_gcno(filename)
#
# Read the contents of the specified .gcno file and return the following
# mapping:
#   graph:    filename -> file_data
#   file_data: function name -> line_data
#   line_data: [ line1, line2, ... ]
#
# See the gcov-io.h file in the gcc 3.3 source code for a description of
# the .gcno format.
#

sub read_gcno($)
{
    my ($gcno_filename) = @_;
    my $file_magic = 0x67636e6f;
    my $tag_function = 0x01000000;
    my $tag_lines = 0x01450000;
    my $big_endian;
    my $word;
    my $tag;
    my $length;
    my $filename;
    my $function;
    my $bb = {};
    my $fileorder = {};
    my $instr;
    my $graph;
    my $filelength;
	my $version;
	my $artificial;
	my @artificial_fns;
    local *HANDLE;

    open(HANDLE, "<", $gcno_filename) or goto open_error;
    $filelength = (stat(HANDLE))[7];
    binmode(HANDLE);
    # Read magic
    $word = read_gcno_word(*HANDLE, "file magic");
    goto incomplete if (!defined($word));
    # Determine file endianness
    if (unpack("N", $word) == $file_magic) {
        $big_endian = 1;
    } elsif (unpack("V", $word) == $file_magic) {
        $big_endian = 0;
    } else {
        goto magic_error;
    }
	# Read version
	$version = read_gcno_value(*HANDLE, $big_endian, "compiler version");
	$version = map_gcno_version($version);
	debug(sprintf("found version 0x%08x\n", $version));
	# Skip stamp
	graph_skip(*HANDLE, 4, "file timestamp") or goto incomplete;
    if ($version >= $GCOV_VERSION_8_0_0) {
        graph_skip(*HANDLE, 4, "support unexecuted blocks flag")
			or goto incomplete;
	}
    while (!eof(HANDLE)) {
        my $next_pos;
        my $curr_pos;

        # Read record tag
        $tag = read_gcno_value(*HANDLE, $big_endian, "record tag");
        goto incomplete if (!defined($tag));
        # Read record length
        $length = read_gcno_value(*HANDLE, $big_endian,
                      "record length");
        goto incomplete if (!defined($length));
        # Convert length to bytes
        $length *= 4;
        # Calculate start of next record
        $next_pos = tell(HANDLE);
        goto tell_error if ($next_pos == -1);
        $next_pos += $length;
        # Catch garbage at the end of a gcno file
        if ($next_pos > $filelength) {
            debug("Overlong record: file_length=$filelength ".
                  "rec_length=$length\n");
            warn("WARNING: $gcno_filename: Overlong record at end ".
                 "of file!\n");
            last;
        }
        # Process record
        if ($tag == $tag_function) {
			($filename, $function, $artificial) =
				read_gcno_function_record(
				*HANDLE, $bb, $fileorder, $big_endian,
				$length, $version);
			goto incomplete if (!defined($function));
			push(@artificial_fns, $function) if ($artificial);
		} elsif ($tag == $tag_lines) {
			# Read lines record
			$filename = read_gcno_lines_record(*HANDLE,
					$gcno_filename, $bb, $fileorder,
					$filename, $function, $big_endian);
			goto incomplete if (!defined($filename));
		} else {
			# Skip record contents
			graph_skip(*HANDLE, $length, "unhandled record")
				or goto incomplete;
		}
		# Ensure that we are at the start of the next record
		$curr_pos = tell(HANDLE);
		goto tell_error if ($curr_pos == -1);
		next if ($curr_pos == $next_pos);
		goto record_error if ($curr_pos > $next_pos);
		graph_skip(*HANDLE, $next_pos - $curr_pos,
			   "unhandled record content")
			or goto incomplete;
	}
	close(HANDLE);
	# Remove artificial functions from result data
	remove_fn_from_hash($bb, \@artificial_fns);
	remove_fn_from_hash($fileorder, \@artificial_fns);
	($instr, $graph) = graph_from_bb($bb, $fileorder, $gcno_filename, 1);
    graph_cleanup($graph);

    return ($instr, $graph);

open_error:
    graph_error($gcno_filename, "could not open file");
    return undef;
incomplete:
    graph_error($gcno_filename, "reached unexpected end of file");
    return undef;
magic_error:
    graph_error($gcno_filename, "found unrecognized gcno file magic");
    return undef;
tell_error:
    graph_error($gcno_filename, "could not determine file position");
    return undef;
record_error:
    graph_error($gcno_filename, "found unrecognized record format");
    return undef;
}

sub debug($)
{
    my ($msg) = @_;

    return if (!$debug);
    print(STDERR "DEBUG: $msg");
}

#
# get_gcov_capabilities
#
# Determine the list of available gcov options.
#

sub get_gcov_capabilities()
{
    my $help = `$gcov_tool --help`;
    my %capabilities;
    my %short_option_translations = (
        'a' => 'all-blocks',
        'b' => 'branch-probabilities',
        'c' => 'branch-counts',
        'f' => 'function-summaries',
        'h' => 'help',
        'l' => 'long-file-names',
        'n' => 'no-output',
        'o' => 'object-directory',
        'p' => 'preserve-paths',
        'u' => 'unconditional-branches',
        'v' => 'version',
    );

    foreach (split(/\n/, $help)) {
        my $capability;
        if (/--(\S+)/) {
            $capability = $1;
        } else {
            # If the line provides a short option, translate it.
            next if (!/^\s*-(\S)\s/);
            $capability = $short_option_translations{$1};
            next if not defined($capability);
        }
        next if ($capability eq 'help');
        next if ($capability eq 'version');
        next if ($capability eq 'object-directory');

        $capabilities{$capability} = 1;
        debug("gcov has capability '$capability'\n");
    }

    return \%capabilities;
}

#
# parse_ignore_errors(@ignore_errors)
#
# Parse user input about which errors to ignore.
#

sub parse_ignore_errors(@)
{
    my (@ignore_errors) = @_;
    my @items;
    my $item;

    return if (!@ignore_errors);

    foreach $item (@ignore_errors) {
        $item =~ s/\s//g;
        if ($item =~ /,/) {
            # Split and add comma-separated parameters
            push(@items, split(/,/, $item));
        } else {
            # Add single parameter
            push(@items, $item);
        }
    }
    foreach $item (@items) {
        my $item_id = $ERROR_ID{lc($item)};

        if (!defined($item_id)) {
            die("ERROR: unknown argument for --ignore-errors: ".
                "$item\n");
        }
        $ignore[$item_id] = 1;
    }
}

#
# is_external(filename)
#
# Determine if a file is located outside of the specified data directories.
#

sub is_external($)
{
    my ($filename) = @_;
    my $dir;

    foreach $dir (@internal_dirs) {
        return 0 if ($filename =~ /^\Q$dir\/\E/);
    }
    return 1;
}

#
# compat_name(mode)
#
# Return the name of compatibility mode MODE.
#

sub compat_name($)
{
    my ($mode) = @_;
    my $name = $COMPAT_MODE_TO_NAME{$mode};

    return $name if (defined($name));

    return "<unknown>";
}

#
# parse_compat_modes(opt)
#
# Determine compatibility mode settings.
#

sub parse_compat_modes($)
{
    my ($opt) = @_;
    my @opt_list;
    my %specified;

    # Initialize with defaults
    %compat_value = %COMPAT_MODE_DEFAULTS;

    # Add old style specifications
    if (defined($opt_compat_libtool)) {
        $compat_value{$COMPAT_MODE_LIBTOOL} =
            $opt_compat_libtool ? $COMPAT_VALUE_ON
                        : $COMPAT_VALUE_OFF;
    }

    # Parse settings
    if (defined($opt)) {
        @opt_list = split(/\s*,\s*/, $opt);
    }
    foreach my $directive (@opt_list) {
        my ($mode, $value);

        # Either
        #   mode=off|on|auto or
        #   mode (implies on)
        if ($directive !~ /^(\w+)=(\w+)$/ &&
            $directive !~ /^(\w+)$/) {
            die("ERROR: Unknown compatibility mode specification: ".
                "$directive!\n");
        }
        # Determine mode
        $mode = $COMPAT_NAME_TO_MODE{lc($1)};
        if (!defined($mode)) {
            die("ERROR: Unknown compatibility mode '$1'!\n");
        }
        $specified{$mode} = 1;
        # Determine value
        if (defined($2)) {
            $value = $COMPAT_NAME_TO_VALUE{lc($2)};
            if (!defined($value)) {
                die("ERROR: Unknown compatibility mode ".
                    "value '$2'!\n");
            }
        } else {
            $value = $COMPAT_VALUE_ON;
        }
        $compat_value{$mode} = $value;
    }
    # Perform auto-detection
    foreach my $mode (sort(keys(%compat_value))) {
        my $value = $compat_value{$mode};
        my $is_autodetect = "";
        my $name = compat_name($mode);

        if ($value == $COMPAT_VALUE_AUTO) {
            my $autodetect = $COMPAT_MODE_AUTO{$mode};

            if (!defined($autodetect)) {
                die("ERROR: No auto-detection for ".
                    "mode '$name' available!\n");
            }

            if (ref($autodetect) eq "CODE") {
                $value = &$autodetect();
                $compat_value{$mode} = $value;
                $is_autodetect = " (auto-detected)";
            }
        }

        if ($specified{$mode}) {
            if ($value == $COMPAT_VALUE_ON) {
                info("Enabling compatibility mode ".
                     "'$name'$is_autodetect\n");
            } elsif ($value == $COMPAT_VALUE_OFF) {
                info("Disabling compatibility mode ".
                     "'$name'$is_autodetect\n");
            } else {
                info("Using delayed auto-detection for ".
                     "compatibility mode ".
                     "'$name'\n");
            }
        }
    }
}

sub compat_hammer_autodetect()
{
        if ($gcov_version_string =~ /suse/i && $gcov_version == 0x30303 ||
            $gcov_version_string =~ /mandrake/i && $gcov_version == 0x30302)
    {
        info("Auto-detected compatibility mode for GCC 3.3 (hammer)\n");
        return $COMPAT_VALUE_ON;
    }
    return $COMPAT_VALUE_OFF;
}

#
# is_compat(mode)
#
# Return non-zero if compatibility mode MODE is enabled.
#

sub is_compat($)
{
    my ($mode) = @_;

    return 1 if ($compat_value{$mode} == $COMPAT_VALUE_ON);
    return 0;
}

#
# is_compat_auto(mode)
#
# Return non-zero if compatibility mode MODE is set to auto-detect.
#

sub is_compat_auto($)
{
    my ($mode) = @_;

    return 1 if ($compat_value{$mode} == $COMPAT_VALUE_AUTO);
    return 0;
}
