/***
	morse.pde: Morse code input/output codec for Bitlash

	Bitlash is a tiny language interpreter that provides a serial port shell environment
	for bit banging and hardware hacking.

	Bitlash lives at: http://bitlash.net
	The author can be reached at: bill@bitlash.net

	Copyright (C) 2008-2012 Bill Roy

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 2.1 of the License, or (at your option) any later version.

    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

***/

/****************

Bitlash morse code example

This example adds morse code output to Bitlash.

There are three new functions:

The function printm() is the main action.  It acts like printf(), but the output
is signalled in morse code on the pins defined below in the configuration section.

Both a positive-going steady-on and a tone output are supported.  
	- connect an LED/resistor to the steady-on output
	- connect a piezo buzzer/resistor to the tone output

The frequency of the sidetone is adjustable using the freq() function (default 800 Hz)

The morse code transmission speed is adjustable using the wpm() function (default 15 wpm) 

A push-to-talk signal is supported, with a configurable keyup delay (default 10ms)

Morse output is blocking.  In this implementation, everything freezes 
while morse is being sent.  It is not ideal.  A little state machine and buffer 
could take care of that.


Example: Send callsign in CW every ten minutes

	function beacon {printm("W1AW");}
	run beacon,10*60*1000
	
Example: Send temperature report in morse code every minute

	function get_temp(...however you get the temperature...)
	function temp_report {printm("temp: %d %u", get_temp(), millis);}
	run temp_report,60*1000

Project: Make a QRP beacon with an oscillator-in-a-can on the ham bands
	- PTT provides/switches power
	- signal using the steady-on output

****************/
#include "bitlash.h"

/***
	TODO: print prosigns BK SK AR correctly
***/


// CONFIGURATION

// Pin Assignments
#define PIN_PTT		3	// any digital pin
#define PIN_TX		4	// any digital pin
#define PIN_TONE	5	// any PWM pin (for tone())

#define DEFAULT_WPM 15	// morse speed in PARIS words per minute

#define PTT_DELAY	10	// ms to delay after pulling PTT high

// Tone handling
#define DEFAULT_SIDETONE 800	// Hz

// END CONFIGURATION




/////////////////////////////////
// The Morsetab
//
// Each value in the table is bit-encoded as lllddddd, where:
//	lll is 3 bits of length [0..7] and 
//	ddddd is 5 bits of morse data, 1==dah and 0==dit
// since there are only 5 bits for morse data we handle 6 element symbols as a special case
// they are stored with a length of zero and an index into 'm6codes', an exception array below
//
#define m(a,b) ((a<<5) + b)
#define m6(b) m(0,b)
#define NIL m(6,0xc)
#include "avr/pgmspace.h"
prog_char morsetab[] PROGMEM = {
	//2 SP      !      "      #    $       %    &        '          (         )      *    +         ,      -      .          slash
		NIL, m6(2), m6(6), NIL, m(7,9), NIL, m(5,8), m(6,0x1e), m(5,0x16), m6(3), NIL, m(5,0xa), m6(4), m6(5), m(6,0x15), m(5,0x12),
	//3   0   		1   		2   	3   	4   		5   	6   	7   		8   		9   	 :  	;  		<    =   	   >    ?
		m(5,0x1f), m(5,0x0f), m(5,7), m(5,3), m(5,1), m(5,0), m(5,0x10), m(5,0x18), m(5,0x1c), m(5,0x1e), m6(0), m6(1), NIL, m(5,0x11), NIL, m(6,0xc),
	//4	@       	a		b		c		d		e		f		g		h			i		j		k		l		m		n		o
		m(6,0x1a), m(2,1), m(4,8), m(4,0xa), m(3,4), m(1,0), m(4,2), m(3,6), m(4,0), m(2,0), m(4,7), m(3,5), m(4,4), m(2,3), m(2,2), m(3,7),
	//5  P   	Q   		R   	S   	T   	U   	V   	W   	X   	Y   		Z     [    \          ]    ^    _
		m(4,6), m(4,0xd), m(3,2), m(3,0), m(1,1), m(3,1), m(4,1), m(3,3), m(4,9), m(4,0xb), m(4,0xc), NIL, m(5,0x12), NIL, NIL, m(6,0xd)
};

/*
$ m(7,9)
*/

#define NUM_SPECIAL_CHARS 13
//                              012345 6789012
prog_char outliers[] PROGMEM = ":;!),-\"'.?@_#";

prog_char m6codes[NUM_SPECIAL_CHARS] PROGMEM = {
//	0=:  1=;  2=!  3=)  4=,  5=-  6="  7='  8=.  9=?  10=@ 11=_ 12=SK/#
	0x38,0x2a,0x2b,0x2d,0x33,0x21,0x12,0x1e,0x15,0x0c,0x1a,0x0d,0x05
};

numvar morse_dit_ms;
numvar morse_dah_ms;
numvar sidetone_freq;

void send_morse_element(int dt) {
	digitalWrite(PIN_TX, 1);
	tone(PIN_TONE, sidetone_freq);
	delay(dt);

	noTone(PIN_TONE);
	digitalWrite(PIN_TX, 0);
	delay(morse_dit_ms);		// symbolspace of silence
}

void sendMorseElementPattern(byte bitcount, byte data) {
	byte mask = 1 << (bitcount-1);
	while (mask) {
		send_morse_element( (data & mask) ? morse_dah_ms : morse_dit_ms );
		mask >>= 1;
	}
	delay(2 * morse_dit_ms);	// letterspace less symbolspace taken above
}

void sendMorseChar(byte c) {
	if (c == ' ') { delay(6 * morse_dit_ms); return; }		// wordspace
	if ((c >= 'a') && (c <= 'z')) c = c - 'a' + 'A';
	if ((c < ' ') || (c > '_')) return;    // ignore bogus 7-bit and all 8-bit
	byte tablecode = pgm_read_byte(morsetab + c - ' ');
	byte len = (tablecode >> 5) & 7;
	if (len) sendMorseElementPattern(len, tablecode & 0x1f);
	else sendMorseElementPattern(6, pgm_read_byte(m6codes + tablecode));
}

void sendMorseString(char *str) {while (*str) sendMorseChar(*str++); }



///////////////////
//
// External API
//
void initMorse(void) {
	setwpm(DEFAULT_WPM);
	sidetone_freq = DEFAULT_SIDETONE;
}


//////////
//
// setwpm(): set words-per-minute
//
numvar func_wpm(void) {
	setwpm(getarg(1));
	return 0;
}

void setwpm(unsigned int wpm) {
	if ((wpm == 0) || (wpm > 1200)) wpm = DEFAULT_SIDETONE;
	morse_dit_ms = (1200 / wpm);
	morse_dah_ms = (3 * (1200 / wpm));
}


//////////
//
// setfreq(): set sidetone frequency
//
numvar func_freq(void) {
	if (getarg(0)) sidetone_freq = getarg(0);
	return 0;
}


//////////
//
// printm(): printf in morse code
//
numvar func_printm(void) {
	setOutputHandler(&sendMorseChar);
	digitalWrite(PIN_PTT, HIGH);
	if (PTT_DELAY) delay(PTT_DELAY);
	extern numvar func_printf_handler(byte, byte);
	func_printf_handler(1,2);	// format=arg(1), optional args start at 2
	resetOutputHandler();
	digitalWrite(PIN_PTT, LOW);
	return 0;
}


//////////////////////////
// Test driver
//
void setup(void) {

	// init output pins
	pinMode(PIN_PTT, OUTPUT); digitalWrite(PIN_PTT, HIGH);
	pinMode(PIN_TX, OUTPUT); digitalWrite(PIN_TX, LOW);
	pinMode(PIN_TONE, OUTPUT); digitalWrite(PIN_TONE, LOW);

	// init morse subsystem
	initMorse();

	// init bitlash last so it can send morse from the startup function
	initBitlash(57600);
	addBitlashFunction("printm", (bitlash_function) func_printm);
	addBitlashFunction("wpm", (bitlash_function) func_wpm);
	addBitlashFunction("freq", (bitlash_function) func_freq);
}

void loop(void) {
	runBitlash();
}


