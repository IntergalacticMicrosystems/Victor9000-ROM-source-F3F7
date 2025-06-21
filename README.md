**Updates:**


Assembled ROM now matches the newer F3F7 version.

Search the ASM files for f3f7 to see the changes.

It could use some work to comment and define the addresses.

I'm compiling on windows - see winbuild.cmd

You'll need Python, alink, jwasm, and GNU dd, make, tail.

A zip with most of those can be found here:

[https://victor9000.com/files/v9k-bios-build.zip](https://victor9000.com/files/v9k-bios-build.zip)

___


This is the source code for the Victor 9000, Sirius 1, and Vicky. I
found the source code here:

http://oldcomputers.dyndns.org/public/pub/roms/victor-sirius/index.html

I added a Makefile so that I could assemble it under Linux. I had to
make a few minor changes to get it to assemble. After adding a couple
of NOPs the output matches the F3F6 version in my Victor *exactly*.

In order to assemble and link you will need a MASM compatible
assembler and linker:

* [JWasm](https://github.com/JWasm/JWasm)
* [Alink](http://alink.sourceforge.net/)

To get Alink to compile on Linux I have provided a patch.

fozztexx@fozztexx.com
