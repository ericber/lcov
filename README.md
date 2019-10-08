Ported to Windows LCOV Code Coverage tool
==================

[LCOV] (http://ltp.sourceforge.net/coverage/lcov.php) is a graphical front-end for GCC's coverage testing tool gcov. It collects gcov data for multiple source files and creates HTML pages containing the source code annotated with coverage information. It also adds overview pages for easy navigation within the file structure. LCOV supports statement, function and branch coverage measurement.

This a fork from valbok. I merged GCC8 support from the linux version. I fixed issues with relative paths in complex projects. The HTML generator now creates all file in one single folder. It also support MINGWIN shell (linux style shell on windows). I also in improved the batch file to define ENV variable used byt the perl scripts.

Installation
============

0. Install Perl if not installed. For example to **C:\Perl**
1. Define correct path of Perl and gcov executables in **lcov.bat**:

    ```
    set PERL_EXE=C://Perl//bin//Perl.exe
    ```
    ```
    set GCOV_EXE=c://MinGW//bin//gcov.exe
    ```

HOW TO USE
==========

1. Compile your project to support [GCOV](https://gcc.gnu.org/onlinedocs/gcc/Invoking-Gcov.html#Invoking-Gcov). As a result *.gcno files will be created.
2. Run your binaries and *.gcda files will be created. You can place them to the same dir with *.gcno.
3. Go to a project root dir where *.gcda and *.gcno files placed.
4. Run **lcov.bat**

    
    ```
    d:\project> d:\lcov\lcov.bat
    Creating gcov\lcov.info ...
    Capturing coverage data from .
    d:\lcov/geninfo.perl . --output-filename gcov/lcov.info --base-directory .Found gcov version: 4.4.2
    Scanning . for .gcda files ...
    ```
    
5. After execution **gcov\html** dir will be created with html reports for current project.
