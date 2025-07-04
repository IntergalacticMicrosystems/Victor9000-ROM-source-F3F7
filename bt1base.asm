include bt1ttl.inc
subttl main driver for boot logic


;
;
;	initial boot program entry (after diagnostics)
;		NOTE: must be first file linked !!!
;


name	btntry;
cgroup	group code;
dgroup	group data;
assume	cs:cgroup


code 	segment public 'code';

	extrn	nt_reset:near;		initialize network driver
	extrn	fd_reset:near;		initialize floppy disk driver
	extrn	hd_reset:near;		initialize hard disk driver
	extrn	char_init:near;		initialize character font table
	extrn	cu_oprn:near;		perform control unit operations
	extrn   FD_not_sure_15BA:near ; f3f7 mod

code	ends;




data	segment public 'data'

	extrn	bstck:word;		boot's stack
	extrn	bootflg:word;		option selection for booting
	extrn	sw_entry:word;		if not to enter O/S, alternate entry	extrn	bootr:word;		boot's buffer in segment 0
	extrn	dot_ram:word;		font table in segment 0
include bt1ul.str
	extrn	cu_table:uls;		current control unit dispatch table
	extrn	char:word;		cursor position
	extrn	char_mode:word;		character attributes
	extrn	blink_toggle:byte;	toggle on/off for blinking arrow
	extrn	b_count:word;		working variable
include bt1bvt.str
	extrn	bvt:bvts;		the boot vector table structure
include bt1lrb.str
	extrn	lrb:lrbs;		load request block structure

data	ends;



;
;	floppy drives (LED's may be used to show we're alive and well)
;
ioports		segment at 0E800h;	6500 address space

		org	0CFh;		same as 0C1, but doesn't reset if read
read_pera	equ	byte ptr $;	sync indicator
f_led0		equ	01h;		output LED for drive A
f_led1		equ	04h;		output LED for drive B

ioports		ends;



;
;	serial port definitions
;

serial	segment public

a_data	db	(0)		; data port "a"
b_data	db	(0)		; data port "b"
a_ctl	db	(0)		; control port "a"
b_ctl	db	(0)		; control port "b"

data_available	equ	1	; data available at the chip
any_errors	equ	30h	; error status bits

serial	ends



;
;	timer chip definitions
;

timer	segment public

adata	db	(0)
bdata	db	(0)
	db	(0)
ctl	db	(0)

timer	ends


;
;	literal values
;
ioport	equ	0FFFFh;		I/O port to scope error code to field service
FE_16K		equ	03h;	FE error unreproducable error in first 16K
FE_internal	equ	04h;	error for field engineering -- internal error
FE_16K_error	equ	30h;	FE error code for error in first 16K
FE_16K_mult	equ	40h;	FE error code for error in first 16K, >1 bit

screen	equ	0F000h;		address of screen ram
as6500	equ	0E800h;		I/O port for 6500 (crt and floppy)
crt_rg	equ	00h;		main CRT I/O register
pio40	equ	040h;		I/O register for CRT brightness
maxchar	equ	79;		maximum character position on line
bright	equ	04000h;		bright attribute for display
blnkflp	equ	31;		count-down timer for how often to blink
one_try	equ	01h;		only attempt booting once
not_rdy	equ	02h;		wait for not ready before retry
q_fail	equ	04h;		quiesce the device if it failed
last_cu	equ	0ffffh;		flag in table of last control unit
ignore	equ	0ff00h;		flag for dummy control unit

;
;	boot's I/O commands for device drivers
;
cu_pres	equ	4000h;		check if control unit present
ready	equ	4001h;		check if device is ready
online	equ	4002h;		put device on-line
read	equ	4003h;		read a block from device
quiesce	equ	4004h;		done, quiesce the device
stat	equ	4005h;		check device's status

include bt1icons.inc





code 	segment public 'code';

public	boot;			entry point
public	fatal_error;		fatal boot error routine
public	time;			waits 100n microseconds
public	err_intern;		internal error handler



;
;	entry point for Diagnostic from Power-on/Reset
;
boot	proc;
	jmp short boot2;	skip over the constants


;
;	constants area in code segment
;


;
;	default unit list table
;
def_unit	equ	$;

;
;	floppy disk (left)--
;
	dw	0000h;		driver/control unit/device
	dw	?;		working counter for floppy insertion timeout
	dw	0FFFFh;		infinite floppy timeout (right drive controls)
	dw	fd_icon;	icon for floppy
	dw	0000H+not_rdy+q_fail;	device type & options

;
;	floppy disk (right)--
;
	dw	0001h;		driver/control unit/device
	dw	?;		working counter for floppy insertion timeout
	dw	blnkflp*2;	timeout for right floppy
	dw	fd_icon;	icon for floppy
	dw	0100H+not_rdy+q_fail;	device type & options

;
;	network--
;
	dw	2000h;		driver/control unit/device
	dw	?;		working floppy insertion timeout counter
	dw	1;		no timeout
	dw	net_icon;	icon for network
	dw	8000h;		device type & retry network

;
;	hard disk--
;
	dw	1000h;		driver/control unit/device
	dw	?;		working floppy insertion timeout counter
	dw	1;		no timeout
	dw	hd_icon;	icon for hard disk
	dw	1000h+one_try;	device type & do not retry hard disk

;
;	end of list
;
	dw	last_cu;	flag end of list

def_unit_size	equ	$-def_unit;



;
;	table of patterns to send to CRT to reset it
;
reset_table	equ	$;
	db	92;
	db	80;
	db	81;
	db	0CFh;
	db	25;
	db	6;
	db	25;
	db	25;
	db	3;
	db	14;
	db	20h;
	db	00;
	db	00;
	db	00;
	db	00;
	db	00;
reset_table_size	equ	$-reset_table;





;
;	entry point for this module . . .
;

;
;	set up data segment, stack segment, and non-maskable interrupts
;
boot2:;					initialization code

	mov	sp,as6500;		establish addressability to crt
	mov	es,sp;
	mov	byte ptr es:[0],1;
	mov	byte ptr es:[1],0;	shut down crt

	xor	ax,ax;
	mov	ds,ax;			establish segment 0 as data area

	mov	word ptr ds:[8],0CFF9h;		set up nmi vector again
	mov	word ptr ds:[0Ah],0F301h;	(trick explained in power-on/reset)

	mov	ss,ax;			segment 0 as stack area, too
	lea	sp,dgroup:bstck;	set up stack area

	assume	ds:dgroup,ss:dgroup;	lie (data segment is not in the ROM)

;
;	set up tables in ram, initialize routines, and clear the screen
;

	push	cs;
	pop	ds;		pointer to unit list table in code segment

	cld;			set to auto-increment pointers in REP's
	lea	si,word ptr cs:def_unit;local image of the unit list
	mov	es,ax;		to segment 0 data area
	lea	di,dgroup:cu_table;	unit list table area in ram
	mov	cx,def_unit_size/2;	number of words to copy
	rep	movsw;		copy table from rom to ram

	mov	ds,ax;		re-establish data segment

	call	char_init;	initialize the character set (font definition)

;
;	set char_mode to contain display attribute and the offset
;	to the font table's first character (from location 0:0)
;
	mov	ax,offset dot_ram;	base of font table
	mov	cl,5;
	shr	ax,cl;		32 bytes per font entry
	add	ax,bright;	low intensity
	mov	char_mode,ax;	low intensity, offset into font

;
;	initialize the CRT
;
	mov	ax,blank;
	add	ax,char_mode;	blank, attribute, and offset into font

	mov	di,screen;
	mov	es,di;		write to screen ram

	xor	di,di;		starting at offset of 0
	mov	cx,80*25;	for each cell on screen
	rep	stosw;		clear the screen

	mov	ax,as6500;	crt registers base address
	mov	es,ax;
	mov	byte ptr es:[pio40],54h;	set brightness and contrast
	mov	byte ptr es:[pio40+2],0FFh;	set data direction register

	call	crt_reset;	reset the CRT controller


; f3f7 mods :00AE
; display version on left bottom corner, maybe
	mov ax, 0FFFFh
	mov es, ax
	db 026h, 0A1h, 0Ah, 00h  	; fixme - mov ax,es:FE_version	- not sure how to bring this in from bt1init.asm
								; prob ok as it just references the hard-coded location near the end of the ROM								
	mov cl,4
	mov bh,al
	shr bh, cl
	mov bl, al
	and bl, 0Fh
	mov al, ah
	shr ah, cl
	and al, 0Fh
	mov cl, 1
	call d_char

; not sure, maybe diff code to blink the drive led(s)
	mov     ax, 0E800h      ; E800h = ioport for 6500 (crt, floppy)
	mov     es, ax
	mov     byte ptr es:0CFh, 5
	xor     bl, bl
	call FD_not_sure_15BA		

	mov     ax, 1388h
	call    time
	and     byte ptr es:0CFh, 0FAh
; --f3f7 mods :00AE

;
;	blink the LED's on the floppies to tell the user we're alive
;
	; mov	ax,seg ioports;	address the floppy registers
	; mov	es,ax;

	; mov	es:[read_pera],f_led0+f_led1;	turn both led's on

	; mov	ax,5000;	wait a half second
	; call	time;

	; and	es:[read_pera],NOT (f_led0+f_led1);	reset the led's

;
;	check for non-fatal errors, and display them if present
;
	cmp	bvt.nfatals,0;		any non-fatal errors ?
	jz	on_to_boot;		no, skip

	mov	cl,baddsk_y;		position for error symbol
	mov	ax,left_x*256+right_x;	icon for X,
	mov	bx,blank*256+0FFh;	a space, and a null
	call	d_char;			display X

	mov	ah,byte ptr bvt.nfatals+1;	high-order errors
	mov	al,ah;
	mov	cl,4;
	shr	ah,cl;			first hex digit
	and	al,0Fh;			second hex digit
	mov	cl,baddsk_y+3;		location of error code (after the X)
	call	d_2_char;

	mov	ah,byte ptr bvt.nfatals;	low-order errors
	mov	al,ah;
	mov	cl,4;
	shr	ah,cl;			first hex digit
	and	al,0Fh;			second hex digit
	mov	cl,baddsk_y+5;		location of error code (after the X)
	call	d_2_char;

	mov	ax,20000;		wait 2 seconds
	call	time;

	call	erase_all;		erase anything left on last line


page
;
;	find out which control units are available to boot from
;
on_to_boot:;

	mov	bp,-(size uls);		will be incremented by bytes per entry

check_cus:;
	add	bp,size uls;		next device

	mov	ax,cu_table.wrk_unit[bp];	check unit's type
	cmp	ax,word ptr last_cu;		at end of table ?
	jz	retry_boot;		yes, done (try to boot)

	mov	ax,cu_table.wrk_unit[bp];	get device type
	cmp	ax,word ptr ignore;		should still try device ?
	jz	check_cus;		no, skip

	mov	lrb.dun,ax;		set into load request block
	mov	lrb.op,cu_pres;		test if control unit is present

	push	bp;			save registers
	call	cu_oprn;		perform the "is it present" test
	pop	bp;			restore registers
	jz	check_cus;		skip if it is present

;
;	device is not present, take is out of the list
;
	mov	cu_table.wrk_unit[bp],ignore;	flag to ignore this device
	jmp	check_cus;		and try another device



;
;	Main Loop . . .
;			infinite loop until a boot results
;

retry_boot:;

;
;	reset variables in all drivers
;
	call	nt_reset;
	call	fd_reset;
	call	hd_reset;

; f3f7 mods :015F
	call erase_all
	xor     bl, bl
	call FD_not_sure_15BA 		
; --f3f7 mods :015F

;
;	test and size memory
;
	cmp	byte ptr bootflg,0;	bypass memory test ?
	jnz	memory_sized;		yes (who ever set flag has sized it)

;
;	there's a problem with taking so long to size and clear memory . . .
;
;		If a floppy is inserted when we're not watching, the motor
;		will not be turned on.  This causes the potential of having
;		the floppy not seated properly (turning the motor on is an
;		important part of the insertion process).  For this reason,
;		poll the floppy frequently during the memory test.
;

	mov	cl,memory_y;		location for the M
	mov	ax,left_m*256+right_m;	display memory test icon, M
	mov	bx,blank*256+0FFh;	a blank, and a null
	call	d_char;

	mov	ax,16*1024/16;		start at 16K in paragraphs
	mov	es,ax;
test_section:;
	mov	ax,055AAh;		test pattern #1
test_pattern:;
	xor	di,di;			offset of zero
	mov	cx,16*1024/2;		length of 16K bytes (8K words)
	rep	stosw;			fill memory

	cmp	ax,word ptr 0;			memory tested and zeroed ?
	jz	section_ok;		yes (for this section)

	xor	di,di;			offset of zero
	mov	cx,16*1024/2;		reset length
	repz	scasw;			test memory
	jnz	memory_tested;		found end of usable memory

	xor	ax,word ptr 0FFFFh;		change to test pattern #2
	jl	test_pattern;		and test with that
	xor	ax,ax;			perform third test pattern
	jmp short test_pattern;

section_ok:;

; f3f7 mods :019F

	mov     ax, es
	add     ax, 400h
	mov     es, ax
	assume es:nothing
	cmp     ax, 0E000h
	jnz     short test_section

; --f3f7 mods :019F

; 	cmp	cu_table.wrk_unit,ignore;
; 	jz	no_floppy_drive;	skip polling if no floppy drives

; 	mov	lrb.dun,0;		check drive 0
; 	mov	lrb.op,ready;		test for device ready

; 	push	es;			save registers
; 	call	cu_oprn;		perform the ready test
; 	inc	word ptr lrb.dun;		check drive 1
; 	call	cu_oprn;		perform the ready test
; 	pop	es;			restore registers

; no_floppy_drive:;
; 	mov	ax,es;
; 	add	ax,16*1024/16;		next 16K (in paragraphs)
; 	mov	es,ax;
; 	cmp	ax,word ptr 896*(1024/16);	at end of memory ?
; 	jnz	test_section;		no, test next 16K

memory_tested:;
	mov	bvt.memsz,es;		save in boot vector table

;
;	have the memory's size, display it
;
memory_sized:;
	mov	bp,ax;			save the test pattern

	mov	ax,bvt.memsz;		fetch memory size in paragraphs
	mov	cl,6;
	shr	ax,cl;			convert to K (size/16/1024)

	mov	bl,10;			convert to decimal
	div	bl;			get ah = unit's digit
	mov	bh,ah;			save unit's digit

	xor	ah,ah;			zero the high-order byte
	div	bl;
	xchg	al,ah;			al = ten's digit
	mov	bl,k;			and a K
	mov	cl,msiz_y;		set cursor to memory size area
	call	d_char;

	test	bvt.memsz,01FFFh;	multiple of 128K ?
	jz	init_screen;		yes, skip

;
;	here when failed a memory test . . . (less than 128K)
;
;	inputs:		es:di addresses the word after the failing location
;			bp is the test pattern which failed
;
	mov	es,bvt.memsz;		get end of memory
	sub	di,2;			point to failing location

	mov	dh,FE_16K_error/10h;	error code is bad bit in first 128K

	mov	bx,es:[di];		read the data which failed
	xor	bx,bp;			compute the incorrect bits
	jz	cannot_reproduce;	cannot reproduce the failure

	mov	dl,15;			start at bit 15
find_failed_bit:;
	cmp	bx,0;			this bit failed ?
	jl	have_failure;		yes, skip out
	shl	bx,1;			look at next bit
	dec	dl;			and update bit's position
	jmp	find_failed_bit;	continue until find the bit

;
;	here if can't find bit that failed, say multiple bits
;
cannot_reproduce:;
	xor	dh,dh;			cannot say which bit failed
	mov	dl,FE_16K;		unreproducable error code
	jmp short display_error;	and output FE information

have_failure:;
	shl	bx,1;			shift out failed bit
	or	bx,bx;			multiple bit error ?
	jz	display_error;		no, skip

	inc	dh;			yes, convert to multi-bit error code
;					(change 30 to 40)
display_error:;
	mov	cl,mem_bits;		location of error code (after the K)
	call	setcrs;

	mov	ah,dh;			high order nibble of error
	call	putch;
	mov	ah,dl;			low order nibble of error
	call	putch;

page


;
;	initialize screen
;
init_screen:;
	and	char_mode,0FFFFh-bright;	screen intensity should be high

;
;
;	Logic to select a device which is able to go ready
;	(that is, present and operational) to boot from.
;
;	cu_table is the list of active devices to choose from.
;

	mov	bp,-(size uls);		will be incremented by bytes per entry

try_boot:;
;
;	loop to find a device which is ready to boot from
;

	mov	b_count,0;		count down for blinking the prompt

	add	bp,size uls;		next device

	mov	ax,cu_table.wrk_unit[bp];	check unit's type
	cmp	ax,word ptr last_cu;		at end of table ?
	jz	serial_boot;		yes, stick in a serial boot
	jmp	not_last;		no, skip

;
;	now, look for a diagnostic boot coming from the serial port
;	(if there is none, we'll look at all the regular devices)
;
;	THIS CODE WAS PROVIDED BY THE DIAGNOSTICS GROUP (EXCUSE THE UPPER-CASE)
;

SERIAL_BOOT:;

;
;	SERIAL BOOT CODE
;
;	PERFORMS BOOT FROM SERIAL PORT IF POSSIBLE
;
;	SERIAL BOOT IS ALWAYS A FIXED LENGTH DOWNLOAD INTO A FIXED
;	LOAD ADDRESS. THIS ROUTINE EXITS TO THE DOWNLOADED CODE IF
;	SUCCESSFUL, OTHERWISE, IT JUST FALLS THROUGH.
;
;
;	GENERAL CONSTANTS
;

LOAD_SEGMENT EQU	0	; BASE SEGMENT FOR LOAD CODE
LOAD_OFFSET  EQU	4000H	; BASE OFFSET FOR LOAD CODE
LOAD_LENGTH  EQU	512	; LENGTH OF LOADER CODE IN BYTES
SERIAL_WAIT  EQU	20000	; DELAY FOR SERIAL ACTION (IN 100 MICROS=2 SECS)
CHAR_TIME    EQU	-1	; DELAY PER CHARACTER
ERR_CHK      EQU	000001B	; CHECKS FOR RECEIVE ERRORS


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
;	SERIAL DOWN LOAD ROUTINE
;
;	assumes	:	load address of LOAD_SEGMENT:LOAD_OFFSET.
;			load length of LOAD_LENGTH.
;			timeout count of SERIAL_WAIT.
;
;	exit conditions:
;			falls thru to end of this code if no boot or
;			failed during attempt.
;
;	or 		If download is successful, control is transfered
;			to LOAD_SEGMENT:LOAD_OFFSET.
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;



;
;	INITIALIZE THE I/O REQUIRED
;

	MOV	AX,0E004H		; SELECT 7201
	MOV	ES,AX
	MOV	AL,BYTE PTR ES:[2]
	MOV	AL,BYTE PTR ES:[3]	; DUMMY READS IN CASE
					; 7201 IS CONFUSED
	MOV	BYTE PTR ES:[2],18H
	MOV	BYTE PTR ES:[3],18H
	
	MOV	BYTE PTR ES:[2],2
	MOV	BYTE PTR ES:[2],10H

	MOV	BYTE PTR ES:[3],2
	MOV	BYTE PTR ES:[3],0

	MOV	BYTE PTR ES:[2],4
	MOV	BYTE PTR ES:[2],47H

	MOV	BYTE PTR ES:[2],3
	MOV	BYTE PTR ES:[2],0C1H

	MOV	BYTE PTR ES:[2],5
	MOV	BYTE PTR ES:[2],0EAH	; 68H

	MOV	BYTE PTR ES:[2],10H
	MOV	BYTE PTR ES:[2],30H

	MOV	BYTE PTR ES:[2],1
	MOV	BYTE PTR ES:[2],04H

	MOV	AX,0E804H		; 6522 FOR CLOCK SELECTION
	MOV	ES,AX
	OR	BYTE PTR ES:[3],3
	AND	BYTE PTR ES:[3],0C3H
	AND	BYTE PTR ES:[1],0FCH

	MOV	AX,0E002H		; 8253 BAUD RATE TIMING
	MOV	ES,AX
	MOV	BYTE PTR ES:[3],36H
	MOV	BYTE PTR ES:[0],41H
	MOV	BYTE PTR ES:[0],0

	MOV	AX,0E004H
	MOV	ES,AX		; ADDRESS THE SERIAL PORT
	ASSUME	ES:SERIAL

	MOV	CX,SERIAL_WAIT	; TIMEOUT FOR WAITING FOR SERIAL BOOT
	MOV	A_CTL,10H	; RESET EXT STATUS
	MOV	A_CTL,30H	; RESET ERRORS

;
;	WAIT TO SEE IF SOMEONE'S TRYING TO LOAD US
;
	
	MOV	AX,0E804H
	MOV	ES,AX			; ADDRESS VIA 2 CS2 (PORT'S STATUS)
	TEST	BYTE PTR ES:[1],0CH	; GET CONTROL LINES' STATUSES
	JNZ	POLL_X			; NO, NO DIAGNOSTIC LOADER OUT THERE

	MOV	AX,0E004H
	MOV	ES,AX		; ADDRESS THE SERIAL PORT
	ASSUME	ES:SERIAL
	TEST	A_CTL,40H	; DATA CARRIER DETECT ?
	JZ	POLL_X		; NO, NOT A DIAGNOSTIC OUT THERE

SLDR:	TEST	A_CTL,DATA_AVAILABLE
	JNZ	DOWN_LOAD	; SOMEONE'S READY TO BOOT US

	MOV	AX,1
	CALL	TIME		; WAIT 100 MICROSECONDS

	LOOP	SLDR		; TIME TO GIVE UP ?
	JMP SHORT NO_SERIAL_BOOT; NO SERIAL BOOT THIS TIME.....


;
;	READ THE CHARACTERS FROM THE SERIAL PORT
;
DOWN_LOAD:
	MOV	BX,LOAD_LENGTH	; SIZE OF LOADER CODE

	MOV	AX,LOAD_SEGMENT	; FIXED DOWN LOAD ADDRESS
	MOV	DS,AX
	MOV	DI,LOAD_OFFSET

LOAD_LP:
	MOV	CX,CHAR_TIME	; MAX WAIT BETWEEN CHARACTERS

POLL:	TEST	A_CTL,DATA_AVAILABLE
	JNZ	DO_READ		; NEXT BYTE IS WAITING
	LOOP	POLL
POLL_X:	JMP SHORT NO_SERIAL_BOOT; TIMED OUT.....OR READ ERROR


DO_READ:
	MOV	AL,A_DATA	; NEXT BYTE FROM PORT
				;       NOTE.....
	MOV	A_CTL,ERR_CHK	; REQUEST STATUS 1 BYTE BUT
	MOV	AH,A_CTL	; MUST DO 'AND' IN CPU'S REGISTER
	AND	AH,ANY_ERRORS	; SINCE DEVICE PAIRS ACCESSES

	JNZ	POLL_X		; NO, HAD A READ ERROR....
	MOV	A_DATA,AL	; GOOD BYTE, ECHO IT
	MOV	DS:[DI],AL	; & STORE AT NEXT ADDRESS
	INC	DI		; POINT TO NEXT LOAD BYTE
	DEC	BX		; COUNT BYTES
	JNZ	LOAD_LP		; REPEAT FOR LENGTH OF DOWN-LOAD
	
;
;	TRANSFER TO CODE JUST LOADED
;
	MOV	WORD PTR DS:[255*4],LOAD_OFFSET;	ADDRESS TO EXECUTE AT
	MOV	WORD PTR DS:[255*4+2],LOAD_SEGMENT
	INT	255		; TRANSFER CONTROL TO DIAGNOSTICS

NO_SERIAL_BOOT:;


page

	xor	bp,bp;			no serial boot, restart at first device

not_last:;

	mov	ax,cu_table.wrk_wait[bp];	time to look at this device
	mov	cu_table.counter[bp],ax;	initialize count-down timer

	cmp	cu_table.wrk_unit[bp],0;	left floppy ?
	jnz	set_blinking;			no, skip

	mov	ax,cu_table.wrk_wait[bp+size uls];	yes, set timeout
	mov	cu_table.counter[bp+size uls],ax;	for right floppy

set_blinking:;
	mov	blink_toggle,0;		initialize blinking variable
	call	blinker;

;
;	process the device (if it hasn't been thrown out of the list)
;
	mov	ax,cu_table.wrk_unit[bp];	get device type
	cmp	ax,word ptr ignore;		should still try device ?
	jnz	process_device;		yes, skip
	jmp	try_boot;		no, skip

process_device:;
	mov	cl,arrow_y+2;		position for device icon
	mov	ax,cu_table.uicon[bp];	first device's icon
	call	d_2_char;

;
;	blink prompt, if we've been on this device for a while
;
retry_this_device:;
	inc	b_count;		count time device in this state
	mov	ax,b_count;
	cmp	ax,word ptr blnkflp;		time to blink ?
	jnz	no_blink;		no, skip

	xor	blink_toggle,1;		toggle blink state (on/off)
	call	blinker;		blink the prompt

	mov	b_count,0;
no_blink:;

;
;	device is present, try to boot from it
;

	mov	ax,cu_table.wrk_unit[bp];	get device type
	mov	lrb.dun,ax;		set into load request block
	mov	lrb.op,ready;		test for device ready

	push	bp;			save registers
	call	cu_oprn;		perform the ready test
	pop	bp;			restore registers
	jz	is_ready;		device is ready, try to boot

	mov	ax,5;			wait 500 microseconds before retrying
	call	time;

	dec	word ptr cu_table.counter[bp];	decrement ready-wait counter
	jnz	floppy_wait;		skip, need to wait
	jmp	try_boot;		timed out, try another boot device

;
;	hit a floppy, must cycle through both drives
;	until ready to boot (the door is closed) or times out
;
floppy_wait:;
	mov	ax,cu_table.wrk_unit[bp];	get device type
	or	ax,ax;			left drive ?
	jz	left_floppy;		yes, skip

	sub	bp,size uls;		right drive, move to left one
	jmp	retry_this_device;

left_floppy:;
	add	bp,size uls;		left drive, move to right one
	jmp	retry_this_device;

;
;	here when a device to boot from is ready
;

is_ready:;
	or	char_mode,bright;	low intensity during the boot

	mov	cl,msiz_y+4;		after the memory size (xxxK)
	mov	dl,80-msiz_y-3;		for the rest of the line
	call	eraser;			erase the 25th line, except memory size

	mov	ax,left_clock*256+right_clock;	select clock icon
	mov	bh,blank;
	mov	bl,byte ptr cu_table.uicon+1[bp];	1st half of deivce icon
	mov	cl,clock_y;		replace arrow with the clock
	call	d_char;			display it

	mov	ah,byte ptr cu_table.uicon[bp];	fetch second half of the icon
	mov	al,blank;
	mov	bh,byte ptr lrb.dun;	get unit number
	and	bh,0Fh;
	mov	bl,blank;
	mov	cl,clock_y+4;
	call	d_char;

;
;	bring the device on-line
;
	mov	lrb.op,online;		operation to perform

	push	bp;			save registers
	call	cu_oprn;		try to bring device on-line
	pop	bp;			restore registers
	jz	device_online;
	jmp	quitdevc;		error in on-line, quit this device

;
;	device on-line, prepare to read the load image
;

device_online:;

;
;	Check if we have sufficient memory to load the image.
;
;	This is done by computing total memory --  minus boot's storage
;	area for variables (400 bytes), minus the size of a boot sector
;	and comparing that to the size of the load image.  All computations
;	are done in paragraphs.
;
;	The size of a sector factors into the calculation because the
;	area just above 400h (our variables) is used as a sector buffer
;	for the last block in a load-high.  This must be done to avoid
;	problems when reading a load image which "just fits."  When this
;	occurs, the memory-mapped I/O would be written over.
;

	mov	ax,lrb.ssz;		get on-line's sector size
	mov	cl,4;
	shr	ax,cl;			divide by 16 bytes per paragraph
	mov	b_count,ax;		and save it (paragraphs per sector)

	mov	bx,bvt.memsz;		get memory in paragraphs
	lea	di,dgroup:dot_ram;
	shr	di,cl;
	sub	bx,di;			low 400h bytes are variables
	sub	bx,ax;			minus size of a sector
	cmp	bx,lrb.loadpara;	compare to size to load
	jae	has_room;
	jmp	no_mem;			load image doesn't fit

;
;	determine address to load the image at
;	(if zero, this means to load it high)
;
has_room:;
	cmp	lrb.loadaddr,0;		load high ?
	jnz	not_high;		no, skip

	mov	bx,bvt.memsz;		yes, load at top of memory
	sub	bx,lrb.loadpara;	minus its size
	mov	lrb.loadaddr,bx;

not_high:;

;
;	check lower bound on absolute load
;
	add	ax,di;			size of a sector plus variables area
	cmp	lrb.loadaddr,ax;	load address below that ?
	jae	enough_room;
	jmp	no_mem;			yes, not enough memory

;
;	It fits !!      Prepare to load it.
;
enough_room:;
	xor	dx,dx;			prepare for division
	mov	ax,lrb.loadpara;	number of paragraphs to load
	div	b_count;		divided by paragraphs in a sector
	mov	lrb.blkcnt,ax;		is number of full blocks to read

	mov	ax,lrb.loadaddr;	paragraph to load at
	mov	word ptr lrb.dma+2,ax;	is segment of the dma
	mov	word ptr lrb.dma,0;	with an offset of zero

	mov	ax,b_count;		paragraphs in a sector
	mul	word ptr lrb.blkcnt;		times number of sectors to read
	mov	b_count,ax;		is actual paragraphs to read

	mov	lrb.op,read;		set operation to read

	push	bp;			save registers
	call	cu_oprn;		read blocks (all but last, partial one)
	pop	bp;			restore registers
	jz	read_ok;
	jmp	quitdevc;		error in reading, give it up

;
;	the entire load image was read, except for a possible
;	final partial block (which must be read into a separate,
;	single-sector buffer)
;
read_ok:;
	mov	ax,b_count;		if still have a partial sector left,
	cmp	ax,word ptr lrb.loadpara;
	jz	none_left;		(skip, nothing left)

	les	di,dword ptr lrb.dma;	remember ending dma address

	mov	word ptr lrb.dma+2,0;	segment of dot_ram is zero
	lea	ax,dgroup:dot_ram;	and offset
	mov	word ptr lrb.dma,ax;	(dot ram is buffer for last sector)

	mov	lrb.blkcnt,1;		read a last single block

	mov	lrb.op,read;		set operation to read

;
;	must turn off the display since we are using the font table area
;	(dot_ram) as a buffer for the last sector
;
	push	bp;			save registers
	push	es;
	push	di;

	mov	bx,0100h;		write a 01 and 00
	call	set_crt_reg;		to turn off the display

	call	cu_oprn;		perform the read

	pop	di;
	pop	es;
	pop	bp;			restore registers

	jz	read_ok2;
	jmp	quitdevc;		quit, error on last read

;
;	copy the last sector (for its actual length) to its home
;
read_ok2:;
	lea	si,dgroup:dot_ram;	copy from dot ram (in data segment)
;					(es:di set up from above dma address)
	mov	ax,lrb.loadpara;	get total paragraphs to load
	sub	ax,b_count;		minus paragraphs loaded before partial
	mov	cl,3;
	shl	ax,cl;			times 8 (8 words per paragraph)
	mov	cx,ax;
	rep	movsw;			load image is now intact
none_left:;

;
;	have the load image memory-resident, pass boot device's code to BIOS
;
	call	crt_restart;		put the screen on, restore dot_ram

	mov	ax,bp;			get offset into driver table
	mov	cl,size uls;		size of table entry
	div	cl;			get driver's number (0,1, . . .)
	mov	dh,al;

	mov	dl,byte ptr cu_table.utype+1[bp];	get driver's code

	cmp	dl,010h;		hard disk ?
	jz	hard_disk_boot;		yes, add in the controller's number

	cmp	dl,080h;		network ?
	jnz	floppy_boot;		no, floppy is ready "as-is"

	mov	al,byte ptr lrb.dun;	get server number
	and	al,0Fh;
	add	dl,al;			and add to low-order nibble
	jmp short floppy_boot;

hard_disk_boot:;
	mov	al,byte ptr lrb.dun;	get which controller
	mov	cl,4;
	shl	al,cl;			get in high-order nibble
	add	dl,al;			and add to low-order byte

floppy_boot:;
	mov	bvt.btdrv,dx;		and store for software

;
;	set up the program's entry point
;
	cmp	word ptr lrb.loadentry+2,0;	entry segment of zero ?
	jnz	have_entry;		no, skip

	mov	ax,lrb.loadaddr;	yes, set entry point
	mov	lrb.loadentry+2,ax;	to load address (in paragraphs)
	mov	lrb.loadentry,0;

have_entry:;
	mov	ax,lrb.loadentry;	set interrupt 255 vector
	mov	cx,lrb.loadentry+2;

	cmp	byte ptr bootflg+1,0;	use regular O/S entry point ?
	jz	jump_to_os_address;	yes, skip

	mov	ax,sw_entry;		set to software's area
	mov	cx,sw_entry+2;

jump_to_os_address:;
	mov	word ptr ds:(255*4),ax;	to the program's entry address
	mov	word ptr ds:(255*4)+2,cx;


;
;	quiesce the load device
;

	mov	lrb.op,quiesce;		operation is to quiesce

	push	bp;			save registers
	call	cu_oprn;		quiesce the device
	pop	bp;			restore registers

;
;	clean it up and go to software
;

	call	erase_all;		erase anything left on last line

	mov	cl,clock_y;		clock position
	mov	ax,left_clock*256+right_clock;	clock icon
	call	d_2_char;		put the clock back on

	int	255;			vector to the software




page
;
;	insufficient memory to load system
;
no_mem:;

	call	crt_restart;		turn the screen back on

	mov	cl,clock_y;		at clock position
	mov	dl,2;			for length of 2
	call	eraser;			turn off the clock icon

	mov	cl,badmem_y;		at memory error area
	jmp short quit;			and quit trying this device


;
;	quit if error with boot device
;
quitdevc:;

	call	crt_restart;		turn the screen back on

	mov	cl,arrow_y;		starting at the arrow icon
	mov	dl,7;			arrow(2),space,icon(2),space,unit number
	call	eraser;			turn off the prompt

	mov	cl,disc_y;		at the device icon
	mov	ax,cu_table.uicon[bp];	fetch device's icon
	call	d_2_char;		turn on the failing device icon

;
;	display a hex encoding of the error
;
	mov	ah,lrb.status;		status is in second byte
	mov	al,ah;
	mov	cl,4;
	shr	ah,cl;			first hex digit
	and	al,0Fh;			second hex digit
	mov	cl,baddsk_y+3;		location of error code (after the X)
	call	d_2_char;

	mov	cl,baddsk_y;		at bad disk area of screen

;
;	quiesce the failing device, if it requires it
;
quit:;
	mov	ax,left_x*256+right_x;	X icon
	mov	bx,blank*256+0FFh;	blank, and a null
	call	d_char;			display X

	test	cu_table.utype[bp],q_fail;
	jz	no_quiesce;		device doesn't require it

	mov	lrb.op,quiesce;		operation is quiesce

	push	bp;			save registers
	call	cu_oprn;		quiesce failing device
	pop	bp;			restore registers

no_quiesce:;

;
;	if device requires it, wait for it to go not-ready
;
	test	cu_table.utype[bp],not_rdy;	should wait for not ready ?
	jz	no_wait;		no, skip

	mov	lrb.op,stat;		operation is test for ready

	push	bp;			save registers
	call	cu_oprn;		perform the ready test
	pop	bp;			restore registers
	jnz	no_wait;		is already "not ready" (wait 2 seconds)

wait_for_not_ready:;
	push	bp;			save registers
	call	cu_oprn;		perform the ready test
	pop	bp;			restore registers
	jz	wait_for_not_ready;	still ready, loop
	jmp short check_ignore;		door opened, can proceed

;
;	device is not to wait, so ensure error message is seen by user
;
no_wait:;
	mov	ax,20000;		wait 2 seconds for a boot error
	call	time;

;
;	if only to try once, set the device to be ignored from now on
;
check_ignore:;
	mov	ax,cu_table.utype[bp];	get device options
	test	ax,one_try;		only try once ?
	jz	no_ignore;		no, skip

	mov	cu_table.wrk_unit[bp],ignore;	set device to be ignored

no_ignore:;
	call	erase_all;		erase screen, will redraw it
	jmp	retry_boot;		retry all devices until a boot results



;
;	routine to handle internal, CPU/MEMORY/PROGRAM errors
;

err_intern	proc;

	call	erase_all;		erase anything left on last line

	mov	cl,baddsk_y;		position for error symbol
	mov	ax,left_x*256+right_x;	icon for X,
	mov	bx,blank*256+0FFh;	a space, and a null
	call	d_char;			display X

;
;	error 69 is an internal error
;
	mov	ah,06h;
	call	putch;
	mov	ah,09h;
	call	putch;

	mov	al,fe_internal;		code for field engineering

;
;	fatal error routine . . .
;
;	input:		al = field service error code
;

fatal_error	proc;

	mov	dx,ioport;		address the field engineering I/O port

fatal_loop:;
	out	dx,al;			let FE scope this error flag
	jmp	fatal_loop;		(continuously)

fatal_error	endp;



err_intern	endp;




;
;	erase the entire last line
;
;	input:	nothing
;
;	returns:	ax,bx,cx,dx,si,es destroyed

erase_all	proc;

	xor	cl,cl;			from first position
	mov	dl,80;			for a length of 80 characters

;					and fall into eraser

erase_all	endp;



;
;	erase characters on the screen
;
;	input:	cl = position to start erasing at
;		dl = length to erase for
;
;	returns:	ax,bx,cx,dx,si,es destroyed
;

eraser	proc;

	call	setcrs;		set cursor to first position

erase_loop:;
	mov	ah,blank;

	call	putch;		erase by writing blanks

	dec	dl;
	jnz	erase_loop;

	ret;

eraser	endp;




;
;	get the CRT going again
;

crt_restart	proc;

	call	char_init;	initialize the font table

;				and fall into crt_reset

crt_restart	endp;




;
;	reset the CRT controller
;
;	send a sequence of bytes to the I/O registers
;

crt_reset	proc;

	mov	cx,reset_table_size;	16 bytes to write
	xor	si,si;			start at byte 0

crt_reset_loop:;
	mov	bx,si;
	xchg	bh,bl;			bh is the byte number
	mov	bl,byte ptr cs:reset_table[si];
	call	set_crt_reg;		and the byte's value written to crt

	inc	si;			increment index
	loop	crt_reset_loop;		until completed

	ret;

crt_reset	endp;








;
;	display 2 characters
;
;	on entry:	ax = indexes of characters to display (see below)
;			cl = position to display the icon at
;
;	returns:	ax, bx, cx, si destroyed
;

d_2_char	proc;

	mov	bx,0FFFFh;	display no third and fourth characters

;				and fall into d_char to display the icon

d_2_char	endp;





;
;	display characters
;
;	input:	cx = position to display characters at
;		ah,al,bh,bl = characters to display (FFh is null)
;
;	returns:	ax,cx,si,es destroyed
;


d_char	proc;

	push	ax;
	push	ax;			save ax

	push	bx;			save bx
	call	setcrs;			set cursor position
	pop	dx;			restore second 2 characters

	pop	ax;			restore ax
	call	putch;			output first character

	pop	ax;			restore ax
	mov	ah,al;
	call	putch;			output second character

	mov	ah,dh;
	call	putch;			third

	mov	ah,dl;			and fourth

;					and fall into putch

d_char	endp;




;
;	put a character to the screen, at the cursor
;
;	input:	ah = character to output
;
;	returns:	ax,bx,cx,si,es destroyed
;

putch	proc;

	cmp	ah,0FFh;		character a null ?
	jz	put_ret;		yes, perform no output

	xchg	al,ah;			put character into low byte
	xor	ah,ah;			zero the high byte
	add	ax,char_mode;		add attribute to character

	mov	si,screen;		pointer to screen ram
	mov	es,si;

	mov	si,char;		get cursor position	
	add	si,si;			double it (screen ram is in words)
	mov	es:[si+(24*80*2)],ax;	write to selected position in screen

	inc	char;			we're on the next position
	mov	cx,char;		get cursor position

;					and fall into setcrs

putch	endp;





;
;	set the cursor at the chosen character position
;
;	input:	cl = position
;
;	destroys:	ax,bx,cx
;

setcrs	proc;

	xor	ch,ch;			high-order byte is unused
	mov	char,cx;		set character on the line

	add	cx,(24*80);		position on last line

	mov	bh,0Eh;
	mov	bl,ch;
	call	set_crt_reg;		and write to the CRT

	mov	bh,0Fh;
	mov	bl,cl;

;					and fall into set_crt_reg

setcrs	endp;



;
;	write 2 bytes to the CRT controller
;
;	input:	bh,bl are the two bytes to write
;
;	returns:	ax,bx destroyed
;

set_crt_reg	proc;

	mov	ax,as6500;	crt registers base address
	mov	es,ax;

	mov	byte ptr es:[crt_rg],bh;

	mov	ax,1;		don't confuse crt controller
	call	time;		wait 100 microseconds

	mov	byte ptr es:[crt_rg+1],bl;

put_ret::
	ret;

set_crt_reg	endp;




;
;	control blinking by turning character on and off
;
;	input:	blink_toggle is (1/0) determining 'on or off'
;
;	returns:	ax, bx, cx, si destroyed
;

blinker	proc;

	mov	cl,arrow_y;		position to display at
	mov	ax,blank*256+blank;	effectively erase the prompt

	cmp	blink_toggle,0;		time to display ?
	jz	blink_off;		no, turn it off

	mov	ax,left_arrow*256+right_arrow;	display the arrow prompt

blink_off:;
	call	d_2_char;		display blanks or an arrow

	ret;

blinker	endp;



;
;	delay for at least n*100 microseconds
;
;	inputs:		ax = n (number of 100mics to wait)
;
;	outputs:	ax destroyed
;
time		proc;

	push	cx;		save caller's registers

	or	ax,ax;		wait for no time at all ?
	jz	time_is_up;	yes, return

time_loop:;
	mov	cl,78h;		fine-tuned constant
	shr	cl,cl;
	dec	ax;		this loop is approximately 100 microseconds
	jnz	time_loop;

time_is_up:;
	pop	cx;		restore caller's registers
	ret;

time		endp;




boot	endp;


code	ends;

end;

