@echo off
::This script has to be called from nrf5x-sensor-hub/tools/nrf5x-sensor-hub-unit-tests/out folder

:: Full dirname of current executable
::set idir=%~dp0
set idir=C://Projects//lcov//
set perl=C://Perl//bin//Perl.exe

md "%CD%\gcov"
echo Creating gcov\lcov.info %idir% ...
::%perl% %idir%lcov.perl -b . -d ./examples/circular_buffer -c -o gcov/lcov.info
echo "Calling: %perl% %idir%lcov.perl --capture -b . -d ./examples/circular_buffer -c -o gcov//lcov.info"
::%perl% %idir%lcov.perl --capture -b .// -d .//examples//circular_buffer -c -o gcov//lcov.info
%perl% %idir%lcov.perl -b .// -d .//examples//circular_buffer -c -o gcov//lcov.info --capture --exclude *gtest* --exclude *googletest* --exclude *mingw* --exclude *circular_buffer_tests.cc*

:: echo Cleaning up ...
:: %perl% %idir%lcov.perl --remove gcov/lcov.info "*_unneeded_*" -o gcov/lcov.info

echo Fixing back slashes ...
type "gcov\lcov.info"|%~dp0repl.bat "\\" "/" >"gcov\lcov.info.tmp"
move /y "gcov\lcov.info.tmp" "gcov\lcov.info" >nul

echo Generating html %idir%genhtml.perl...
%perl% %idir%genhtml.perl -o gcov/html/ gcov/lcov.info -p "%CD%"
