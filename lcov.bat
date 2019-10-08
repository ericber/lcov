@echo off
::This script has to be called from nrf5x-sensor-hub/tools/nrf5x-sensor-hub-unit-tests/out folder

IF DEFINED PERL_EXE (
echo PERL_EXE defined as %PERL_EXE%
)ELSE (
echo WARNING PERL_EXE not defined reverting to default
set PERL_EXE=C://Perl//bin//Perl.exe
)
ENDLOCAL

IF DEFINED GCOV_EXE (
echo GCOV_EXE defined as %GCOV_EXE%
)ELSE (
echo WARNING GCOV_EXE not defined reverting to default
set GCOV_EXE=c://MinGW//bin//gcov.exe
)
ENDLOCAL

IF DEFINED GCNO_GCDA_RELATIVE_PATH (
echo GCNO_GCDA_RELATIVE_PATH defined as %GCNO_GCDA_RELATIVE_PATH%
)ELSE (
echo ERROR GCNO_GCDA_RELATIVE_PATH not defined reverting to example
set GCNO_GCDA_RELATIVE_PATH=.//
)
ENDLOCAL

IF DEFINED COVERAGE_EXCLUSION_LIST (
echo  COVERAGE_EXCLUSION_LIST defined as %COVERAGE_EXCLUSION_LIST%
)ELSE (
echo ERROR COVERAGE_EXCLUSION_LIST not defined reverting to example
set COVERAGE_EXCLUSION_LIST=--exclude *mingw*  --exclude *googletest*  --exclude *googlemock* --exclude *mock* --exclude *fake* --exclude *tests*
)
ENDLOCAL

set LCOV_HOME=%~dp0

md "%CD%\gcov"
echo Creating gcov\lcov.info %LCOV_HOME% ...
%PERL_EXE% %LCOV_HOME%lcov.perl -b .// -d %GCNO_GCDA_RELATIVE_PATH% -c -o .//gcov//lcov.info --capture  %COVERAGE_EXCLUSION_LIST%

::echo Cleaning up ...
::%PERL_EXE% %LCOV_HOME%lcov.perl --remove gcov/lcov.info "*_unneeded_*" -o gcov/lcov.info

echo Fixing back slashes ...
type "gcov\lcov.info"|%~dp0repl.bat "\\" "/" >"gcov\lcov.info.tmp"
move /y "gcov\lcov.info.tmp" "gcov\lcov.info" >nul

echo Generating html %LCOV_HOME%genhtml.perl...
%PERL_EXE% %LCOV_HOME%genhtml.perl -o .//gcov/html/ .//gcov//lcov.info -p "%CD%" --highlight --branch-coverage

