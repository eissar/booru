package slop_pdqhash

import "base:intrinsics"

// Pure Odin port of darwinium-com/pdqhash (Apache-2.0), implementing Meta's
// ThreatExchange PDQ perceptual hash algorithm (256-bit hash + 0..1 quality).

LUMA_FROM_R_COEFF :: f32(0.299)
LUMA_FROM_G_COEFF :: f32(0.587)
LUMA_FROM_B_COEFF :: f32(0.114)

MIN_HASHABLE_DIM :: 5
PDQ_NUM_JAROSZ_XY_PASSES :: 2

BUFFER_W_H :: 64
DCT_OUTPUT_W_H :: 16
DCT_OUTPUT_MATRIX_SIZE :: DCT_OUTPUT_W_H * DCT_OUTPUT_W_H
HASH_LENGTH :: DCT_OUTPUT_MATRIX_SIZE / 8 // 32 bytes (256 bits)

Hash :: [HASH_LENGTH]u8

// Bit-exact IEEE-754 f32 DCT-II matrix (rows 1..16 of 64x64) from Meta PDQ / darwinium-com/pdqhash.
@(private = "file")
DCT_MATRIX := [DCT_OUTPUT_W_H][BUFFER_W_H]u32 {
	{
		0x3e34f6fe,
		0x3e348763,
		0x3e33a872,
		0x3e325ab4,
		0x3e309ef6,
		0x3e2e764c,
		0x3e2be209,
		0x3e28e3c6,
		0x3e257d59,
		0x3e21b0dd,
		0x3e1d80a8,
		0x3e18ef51,
		0x3e13ffa8,
		0x3e0eb4b9,
		0x3e0911c7,
		0x3e031a4c,
		0x3df9a3ec,
		0x3dec794b,
		0x3ddebcd5,
		0x3dd076fe,
		0x3dc1b099,
		0x3db272be,
		0x3da2c6d4,
		0x3d92b688,
		0x3d824bc0,
		0x3d632139,
		0x3d411ee4,
		0x3d1ea56f,
		0x3cf79447,
		0x3cb144ff,
		0x3c5510c6,
		0x3b8e284e,
		0xbb8e286f,
		0xbc5510d6,
		0xbcb14507,
		0xbcf79450,
		0xbd1ea573,
		0xbd411ee8,
		0xbd63213c,
		0xbd824bc2,
		0xbd92b689,
		0xbda2c6d6,
		0xbdb272bd,
		0xbdc1b09a,
		0xbdd076fe,
		0xbddebcd7,
		0xbdec794d,
		0xbdf9a3f1,
		0xbe031a4d,
		0xbe0911c7,
		0xbe0eb4b9,
		0xbe13ffa8,
		0xbe18ef52,
		0xbe1d80a9,
		0xbe21b0dd,
		0xbe257d59,
		0xbe28e3c6,
		0xbe2be20a,
		0xbe2e764c,
		0xbe309ef7,
		0xbe325ab4,
		0xbe33a871,
		0xbe348763,
		0xbe34f6fe,
	},
	{
		0x3e34cd21,
		0x3e330f61,
		0x3e2f982b,
		0x3e2a700c,
		0x3e23a3b9,
		0x3e1b43f5,
		0x3e116566,
		0x3e062061,
		0x3df3215b,
		0x3dd7aa8b,
		0x3dba2004,
		0x3d9aca9f,
		0x3d73ef2e,
		0x3d2fefb8,
		0x3cd47d0b,
		0x3c0e1d77,
		0xbc0e1d88,
		0xbcd47d12,
		0xbd2fefbb,
		0xbd73ef32,
		0xbd9aca9e,
		0xbdba2005,
		0xbdd7aa8c,
		0xbdf3215e,
		0xbe062062,
		0xbe116567,
		0xbe1b43f5,
		0xbe23a3b9,
		0xbe2a700c,
		0xbe2f982b,
		0xbe330f61,
		0xbe34cd21,
		0xbe34cd21,
		0xbe330f61,
		0xbe2f982b,
		0xbe2a700c,
		0xbe23a3b8,
		0xbe1b43f4,
		0xbe116566,
		0xbe062061,
		0xbdf3215b,
		0xbdd7aa88,
		0xbdba2006,
		0xbd9aca9a,
		0xbd73ef2f,
		0xbd2fefae,
		0xbcd47d03,
		0xbc0e1d39,
		0x3c0e1d98,
		0x3cd47d04,
		0x3d2fefc5,
		0x3d73ef31,
		0x3d9acaa5,
		0x3dba2006,
		0x3dd7aa8a,
		0x3df3215f,
		0x3e062061,
		0x3e116568,
		0x3e1b43f6,
		0x3e23a3ba,
		0x3e2a700c,
		0x3e2f982b,
		0x3e330f62,
		0x3e34cd21,
	},
	{
		0x3e348763,
		0x3e309ef6,
		0x3e28e3c6,
		0x3e1d80a8,
		0x3e0eb4b9,
		0x3df9a3ec,
		0x3dd07700,
		0x3da2c6d4,
		0x3d63213e,
		0x3cf79447,
		0x3b8e287b,
		0xbcb14507,
		0xbd411ee2,
		0xbd92b689,
		0xbdc1b09a,
		0xbdec794d,
		0xbe0911c7,
		0xbe18ef50,
		0xbe257d59,
		0xbe2e764c,
		0xbe33a871,
		0xbe34f6fe,
		0xbe325ab4,
		0xbe2be209,
		0xbe21b0dd,
		0xbe13ffa9,
		0xbe031a4c,
		0xbddebcd5,
		0xbdb272be,
		0xbd824bc3,
		0xbd1ea576,
		0xbc5510f9,
		0x3c5510fd,
		0x3d1ea578,
		0x3d824bc4,
		0x3db272be,
		0x3ddebcd5,
		0x3e031a4c,
		0x3e13ffa7,
		0x3e21b0dc,
		0x3e2be20b,
		0x3e325ab4,
		0x3e34f6fe,
		0x3e33a871,
		0x3e2e764c,
		0x3e257d59,
		0x3e18ef52,
		0x3e0911c8,
		0x3dec7949,
		0x3dc1b095,
		0x3d92b687,
		0x3d411ee1,
		0x3cb14505,
		0xbb8e2857,
		0xbcf7943f,
		0xbd63214a,
		0xbda2c6cf,
		0xbdd07703,
		0xbdf9a3e7,
		0xbe0eb4b9,
		0xbe1d80ab,
		0xbe28e3c5,
		0xbe309ef8,
		0xbe348763,
	},
	{
		0x3e3425ce,
		0x3e2d3986,
		0x3e1fa511,
		0x3e0bee0a,
		0x3de5acc6,
		0x3daaa9f0,
		0x3d523043,
		0x3c8df1a8,
		0xbc8df1b0,
		0xbd523047,
		0xbdaaa9f4,
		0xbde5acc6,
		0xbe0bee0a,
		0xbe1fa513,
		0xbe2d3986,
		0xbe3425ce,
		0xbe3425ce,
		0xbe2d3986,
		0xbe1fa511,
		0xbe0bee09,
		0xbde5acc7,
		0xbdaaa9f1,
		0xbd52303f,
		0xbc8df195,
		0x3c8df1c4,
		0x3d523055,
		0x3daaa9f1,
		0x3de5acc7,
		0x3e0bee0b,
		0x3e1fa513,
		0x3e2d3987,
		0x3e3425cf,
		0x3e3425ce,
		0x3e2d3986,
		0x3e1fa510,
		0x3e0bee08,
		0x3de5acc0,
		0x3daaa9ea,
		0x3d523046,
		0x3c8df1a3,
		0xbc8df1b5,
		0xbd523050,
		0xbdaaa9ee,
		0xbde5accd,
		0xbe0bee0a,
		0xbe1fa515,
		0xbe2d3986,
		0xbe3425cf,
		0xbe3425ce,
		0xbe2d3986,
		0xbe1fa50f,
		0xbe0bee0a,
		0xbde5acbb,
		0xbdaaa9ed,
		0xbd52304d,
		0xbc8df184,
		0x3c8df1a7,
		0x3d52305e,
		0x3daaa9f5,
		0x3de5acd3,
		0x3e0bee0c,
		0x3e1fa511,
		0x3e2d3988,
		0x3e3425ce,
	},
	{
		0x3e33a872,
		0x3e28e3c6,
		0x3e13ffa8,
		0x3dec794b,
		0x3da2c6d4,
		0x3d1ea56f,
		0xbb8e289d,
		0xbd411ee8,
		0xbdb272c2,
		0xbdf9a3f1,
		0xbe18ef52,
		0xbe2be20a,
		0xbe348763,
		0xbe325ab4,
		0xbe257d59,
		0xbe0eb4b9,
		0xbddebcd5,
		0xbd92b683,
		0xbcf7944a,
		0x3c5510fd,
		0x3d632151,
		0x3dc1b09c,
		0x3e031a4f,
		0x3e1d80a9,
		0x3e2e764d,
		0x3e34f6fe,
		0x3e309ef6,
		0x3e21b0dd,
		0x3e0911c4,
		0x3dd076f5,
		0x3d824bbc,
		0x3cb144d8,
		0xbcb14518,
		0xbd824bcb,
		0xbdd07703,
		0xbe0911c6,
		0xbe21b0e0,
		0xbe309ef8,
		0xbe34f6fe,
		0xbe2e764a,
		0xbe1d80a5,
		0xbe031a4a,
		0xbdc1b097,
		0xbd63211d,
		0xbc55107e,
		0x3cf7945c,
		0x3d92b69d,
		0x3ddebce1,
		0x3e0eb4bb,
		0x3e257d59,
		0x3e325ab5,
		0x3e348763,
		0x3e2be209,
		0x3e18ef4b,
		0x3df9a3e1,
		0x3db272b4,
		0x3d411eda,
		0x3b8e2714,
		0xbd1ea58f,
		0xbda2c6de,
		0xbdec7961,
		0xbe13ffae,
		0xbe28e3c8,
		0xbe33a872,
	},
	{
		0x3e330f61,
		0x3e23a3b9,
		0x3e062061,
		0x3dba2004,
		0x3d2fefbd,
		0xbc0e1d88,
		0xbd73ef2c,
		0xbdd7aa8c,
		0xbe116566,
		0xbe2a700c,
		0xbe34cd21,
		0xbe2f982b,
		0xbe1b43f6,
		0xbdf3215b,
		0xbd9aca9a,
		0xbcd47d03,
		0x3cd47d04,
		0x3d9aca9a,
		0x3df3215f,
		0x3e1b43f6,
		0x3e2f982b,
		0x3e34cd21,
		0x3e2a700b,
		0x3e116565,
		0x3dd7aa8b,
		0x3d73ef36,
		0x3c0e1d55,
		0xbd2fefbe,
		0xbdba2004,
		0xbe06205f,
		0xbe23a3b8,
		0xbe330f60,
		0xbe330f60,
		0xbe23a3b7,
		0xbe06205f,
		0xbdba2004,
		0xbd2fefbc,
		0x3c0e1d5f,
		0x3d73ef22,
		0x3dd7aa84,
		0x3e11656a,
		0x3e2a700d,
		0x3e34cd21,
		0x3e2f982b,
		0x3e1b43f5,
		0x3df3215e,
		0x3d9acaa4,
		0x3cd47d2d,
		0xbcd47d34,
		0xbd9acaa5,
		0xbdf3215f,
		0xbe1b43f6,
		0xbe2f982b,
		0xbe34cd21,
		0xbe2a700d,
		0xbe116562,
		0xbdd7aa95,
		0xbd73ef20,
		0xbc0e1e06,
		0x3d2fefc0,
		0x3dba2017,
		0x3e062060,
		0x3e23a3bd,
		0x3e330f60,
	},
	{
		0x3e325ab4,
		0x3e1d80a8,
		0x3dec794b,
		0x3d824bc0,
		0x3b8e284e,
		0xbd632142,
		0xbddebcd7,
		0xbe18ef52,
		0xbe309ef7,
		0xbe33a871,
		0xbe21b0db,
		0xbdf9a3e9,
		0xbd92b683,
		0xbc55109f,
		0x3d411ef2,
		0x3dd07706,
		0x3e13ffaa,
		0x3e2e764d,
		0x3e348763,
		0x3e257d57,
		0x3e031a49,
		0x3da2c6cb,
		0x3cb144d8,
		0xbd1ea571,
		0xbdc1b0ad,
		0xbe0eb4b9,
		0xbe2be20d,
		0xbe34f6fe,
		0xbe28e3c1,
		0xbe0911c6,
		0xbdb272a6,
		0xbcf79439,
		0x3cf794b5,
		0x3db272c2,
		0x3e0911d0,
		0x3e28e3c7,
		0x3e34f6ff,
		0x3e2be209,
		0x3e0eb4af,
		0x3dc1b092,
		0x3d1ea533,
		0xbcb14528,
		0xbda2c6f1,
		0xbe031a50,
		0xbe257d60,
		0xbe348763,
		0xbe2e7648,
		0xbe13ffa4,
		0xbdd076e2,
		0xbd411eca,
		0x3c5511f5,
		0x3d92b695,
		0x3df9a409,
		0x3e21b0e0,
		0x3e33a874,
		0x3e309ef5,
		0x3e18ef47,
		0x3ddebcc8,
		0x3d6320f1,
		0xbb8e2991,
		0xbd824be8,
		0xbdec795b,
		0xbe1d80b3,
		0xbe325ab5,
	},
	{
		0x3e318a85,
		0x3e168317,
		0x3dc9234d,
		0x3d0d42ab,
		0xbd0d42af,
		0xbdc92351,
		0xbe168318,
		0xbe318a86,
		0xbe318a85,
		0xbe168316,
		0xbdc92348,
		0xbd0d42b2,
		0x3d0d42b3,
		0x3dc92352,
		0x3e168317,
		0x3e318a86,
		0x3e318a85,
		0x3e168314,
		0x3dc9234b,
		0x3d0d42a3,
		0xbd0d42ac,
		0xbdc9234f,
		0xbe168319,
		0xbe318a86,
		0xbe318a84,
		0xbe168312,
		0xbdc9234f,
		0xbd0d42aa,
		0x3d0d42bb,
		0x3dc92357,
		0x3e16831b,
		0x3e318a87,
		0x3e318a86,
		0x3e168316,
		0x3dc92348,
		0x3d0d429a,
		0xbd0d42ca,
		0xbdc9235c,
		0xbe168317,
		0xbe318a86,
		0xbe318a85,
		0xbe168314,
		0xbdc92355,
		0xbd0d428c,
		0x3d0d42ad,
		0x3dc92363,
		0x3e168319,
		0x3e318a89,
		0x3e318a84,
		0x3e168319,
		0x3dc9233c,
		0x3d0d42a9,
		0xbd0d42e9,
		0xbdc92357,
		0xbe168315,
		0xbe318a87,
		0xbe318a86,
		0xbe168310,
		0xbdc92348,
		0xbd0d426d,
		0x3d0d42cb,
		0x3dc9234a,
		0x3e16831d,
		0x3e318a86,
	},
	{
		0x3e309ef6,
		0x3e0eb4b9,
		0x3da2c6d4,
		0x3b8e287b,
		0xbd92b689,
		0xbe0911c7,
		0xbe2e764c,
		0xbe325ab4,
		0xbe13ffa9,
		0xbdb272be,
		0xbc5510f9,
		0x3d824bc4,
		0x3e031a4c,
		0x3e2be20b,
		0x3e33a871,
		0x3e18ef52,
		0x3dc1b095,
		0x3cb14505,
		0xbd63214a,
		0xbdf9a3e7,
		0xbe28e3c5,
		0xbe348763,
		0xbe1d80ab,
		0xbdd07701,
		0xbcf79439,
		0x3d411ef9,
		0x3dec794a,
		0x3e257d59,
		0x3e34f6fe,
		0x3e21b0de,
		0x3ddebcd3,
		0x3d1ea560,
		0xbd1ea562,
		0xbddebcd5,
		0xbe21b0de,
		0xbe34f6fe,
		0xbe257d59,
		0xbdec7959,
		0xbd411eca,
		0x3cf79440,
		0x3dd076f0,
		0x3e1d80ab,
		0x3e348763,
		0x3e28e3c9,
		0x3df9a3e5,
		0x3d632147,
		0xbcb144b2,
		0xbdc1b0a0,
		0xbe18ef4f,
		0xbe33a873,
		0xbe2be209,
		0xbe031a4f,
		0xbd824bad,
		0x3c551107,
		0x3db272b6,
		0x3e13ffae,
		0x3e325ab4,
		0x3e2e764d,
		0x3e0911c0,
		0x3d92b685,
		0xbb8e27b4,
		0xbda2c6e5,
		0xbe0eb4b9,
		0xbe309ef5,
	},
	{
		0x3e2f982b,
		0x3e062060,
		0x3d73ef2e,
		0xbcd47d12,
		0xbdd7aa8c,
		0xbe23a3b9,
		0xbe34cd21,
		0xbe1b43f4,
		0xbdba1ffd,
		0xbc0e1d39,
		0x3d9acaa5,
		0x3e116568,
		0x3e330f62,
		0x3e2a700b,
		0x3df3215a,
		0x3d2fefb5,
		0xbd2fefbe,
		0xbdf32165,
		0xbe2a700c,
		0xbe330f60,
		0xbe116560,
		0xbd9aca96,
		0x3c0e1e14,
		0x3dba200b,
		0x3e1b43f9,
		0x3e34cd21,
		0x3e23a3b6,
		0x3dd7aa88,
		0x3cd47cd3,
		0xbd73ef5c,
		0xbe062065,
		0xbe2f982e,
		0xbe2f982a,
		0xbe06205a,
		0xbd73ef20,
		0x3cd47cf9,
		0x3dd7aaa2,
		0x3e23a3bd,
		0x3e34cd21,
		0x3e1b43ec,
		0x3dba1fee,
		0x3c0e1d14,
		0xbd9aca9f,
		0xbe116570,
		0xbe330f62,
		0xbe2a700a,
		0xbdf3213c,
		0xbd2fef80,
		0x3d2fefdd,
		0x3df32161,
		0x3e2a7012,
		0x3e330f5f,
		0x3e116562,
		0x3d9aca73,
		0xbc0e1e94,
		0xbdba2019,
		0xbe1b43f8,
		0xbe34cd22,
		0xbe23a3b2,
		0xbdd7aa7b,
		0xbcd47c3a,
		0x3d73ef7a,
		0x3e06206a,
		0x3e2f982d,
	},
	{
		0x3e2e764c,
		0x3df9a3ec,
		0x3d1ea56a,
		0xbd632142,
		0xbe0911c9,
		0xbe325ab4,
		0xbe28e3c5,
		0xbddebccb,
		0xbcb144f7,
		0x3d92b68e,
		0x3e13ffaa,
		0x3e348763,
		0x3e21b0da,
		0x3dc1b08b,
		0x3b8e2757,
		0xbdb272cf,
		0xbe1d80ab,
		0xbe34f6fe,
		0xbe18ef4d,
		0xbda2c6ba,
		0x3c551178,
		0x3dd07708,
		0x3e257d5e,
		0x3e33a871,
		0x3e0eb4af,
		0x3d824bad,
		0xbcf794d5,
		0xbdec7961,
		0xbe2be20c,
		0xbe309ef3,
		0xbe031a45,
		0xbd411eca,
		0x3d411f42,
		0x3e031a5a,
		0x3e309efa,
		0x3e2be206,
		0x3dec7943,
		0x3cf79385,
		0xbd824be8,
		0xbe0eb4c2,
		0xbe33a873,
		0xbe257d4d,
		0xbdd076d5,
		0xbc550f87,
		0x3da2c6f2,
		0x3e18ef57,
		0x3e34f6ff,
		0x3e1d809c,
		0x3db27299,
		0xbb8e2a88,
		0xbdc1b0d3,
		0xbe21b0ea,
		0xbe348761,
		0xbe13ff9c,
		0xbd92b66a,
		0x3cb1461b,
		0x3ddebd06,
		0x3e28e3cf,
		0x3e325ab0,
		0x3e0911ac,
		0x3d63210c,
		0xbd1ea5e9,
		0xbdf9a434,
		0xbe2e7652,
	},
	{
		0x3e2d3986,
		0x3de5acc6,
		0x3c8df1a8,
		0xbdaaa9f4,
		0xbe1fa511,
		0xbe3425ce,
		0xbe0bee0b,
		0xbd52303f,
		0x3d523040,
		0x3e0bee0b,
		0x3e3425ce,
		0x3e1fa510,
		0x3daaa9f4,
		0xbc8df1b5,
		0xbde5accd,
		0xbe2d3986,
		0xbe2d3986,
		0xbde5accc,
		0xbc8df184,
		0x3daaa9f5,
		0x3e1fa511,
		0x3e3425cf,
		0x3e0bee07,
		0x3d52303f,
		0xbd523042,
		0xbe0bee07,
		0xbe3425cf,
		0xbe1fa510,
		0xbdaaa9f3,
		0x3c8df18b,
		0x3de5acbc,
		0x3e2d3983,
		0x3e2d3983,
		0x3de5acbb,
		0x3c8df182,
		0xbdaaa9f6,
		0xbe1fa511,
		0xbe3425cf,
		0xbe0bee0e,
		0xbd523068,
		0x3d52306d,
		0x3e0bee0e,
		0x3e3425cf,
		0x3e1fa510,
		0x3daaa9f3,
		0xbc8df18d,
		0xbde5acbc,
		0xbe2d3983,
		0xbe2d3983,
		0xbde5acb9,
		0xbc8df180,
		0x3daaa9f6,
		0x3e1fa511,
		0x3e3425cf,
		0x3e0bee0e,
		0x3d523010,
		0xbd523019,
		0xbe0bee0f,
		0xbe3425cd,
		0xbe1fa510,
		0xbdaaa9ca,
		0x3c8df18f,
		0x3de5acdf,
		0x3e2d3983,
	},
	{
		0x3e2be209,
		0x3dd076fe,
		0xbb8e286f,
		0xbddebcd7,
		0xbe2e764c,
		0xbe28e3c5,
		0xbdc1b092,
		0x3c5510fd,
		0x3dec794e,
		0x3e309ef6,
		0x3e257d57,
		0x3db272b7,
		0xbcb14518,
		0xbdf9a3f8,
		0xbe325ab4,
		0xbe21b0db,
		0xbda2c6cf,
		0x3cf7945c,
		0x3e031a4d,
		0x3e33a872,
		0x3e1d80a3,
		0x3d92b678,
		0xbd1ea58f,
		0xbe0911cc,
		0xbe348763,
		0xbe18ef4e,
		0xbd824bbb,
		0x3d411eec,
		0x3e0eb4b9,
		0x3e34f6fe,
		0x3e13ffa9,
		0x3d632147,
		0xbd632184,
		0xbe13ffb2,
		0xbe34f6fd,
		0xbe0eb4af,
		0xbd411eac,
		0x3d824bda,
		0x3e18ef57,
		0x3e348762,
		0x3e0911c0,
		0x3d1ea54f,
		0xbd92b696,
		0xbe1d80ab,
		0xbe33a871,
		0xbe031a49,
		0xbcf79435,
		0x3da2c6d8,
		0x3e21b0e7,
		0x3e325ab0,
		0x3df9a3f1,
		0x3cb14469,
		0xbdb272b6,
		0xbe257d60,
		0xbe309ef8,
		0xbdec7936,
		0xbc550e91,
		0x3dc1b0ae,
		0x3e28e3d2,
		0x3e2e7649,
		0x3ddebca3,
		0x3b8e2775,
		0xbdd0772f,
		0xbe2be20b,
	},
	{
		0x3e2a700c,
		0x3dba2004,
		0xbcd47d12,
		0xbe062062,
		0xbe34cd21,
		0xbe116565,
		0xbd2fefae,
		0x3d9acaa5,
		0x3e23a3ba,
		0x3e2f982a,
		0x3dd7aa83,
		0xbc0e1dd5,
		0xbdf32165,
		0xbe330f62,
		0xbe1b43f2,
		0xbd73ef11,
		0x3d73ef4d,
		0x3e1b43f9,
		0x3e330f5f,
		0x3df3214e,
		0x3c0e1cda,
		0xbdd7aa9c,
		0xbe2f982e,
		0xbe23a3b8,
		0xbd9aca74,
		0x3d2fefc0,
		0x3e116575,
		0x3e34cd21,
		0x3e062050,
		0x3cd47cf0,
		0xbdba2032,
		0xbe2a700d,
		0xbe2a7002,
		0xbdba1ffd,
		0x3cd47de9,
		0x3e062065,
		0x3e34cd22,
		0x3e116562,
		0x3d2fef45,
		0xbd9acaad,
		0xbe23a3c7,
		0xbe2f9829,
		0xbdd7aa57,
		0x3c0e1e1d,
		0x3df3218c,
		0x3e330f62,
		0x3e1b43e3,
		0x3d73ef02,
		0xbd73efb3,
		0xbe1b43fc,
		0xbe330f5b,
		0xbdf32147,
		0xbc0e1b2a,
		0x3dd7aaa3,
		0x3e2f9835,
		0x3e23a3b2,
		0x3d9aca57,
		0xbd2feffc,
		0xbe11657e,
		0xbe34cd20,
		0xbe062045,
		0xbcd47c73,
		0x3dba204d,
		0x3e2a7013,
	},
	{
		0x3e28e3c6,
		0x3da2c6d4,
		0xbd411ee2,
		0xbe18ef50,
		0xbe325ab4,
		0xbddebcd5,
		0x3c5510fd,
		0x3e031a4c,
		0x3e34f6fe,
		0x3e0911c8,
		0x3cb14505,
		0xbdd07703,
		0xbe309ef8,
		0xbe1d80ab,
		0xbd632147,
		0x3d92b687,
		0x3e257d59,
		0x3e2be209,
		0x3db272b4,
		0xbd1ea562,
		0xbe13ffa7,
		0xbe33a871,
		0xbdec7959,
		0x3b8e27ab,
		0x3df9a3e8,
		0x3e348763,
		0x3e0eb4b9,
		0x3cf79438,
		0xbdc1b0a0,
		0xbe2e764e,
		0xbe21b0d8,
		0xbd824bad,
		0x3d824baf,
		0x3e21b0d9,
		0x3e2e764d,
		0x3dc1b09d,
		0xbcf79443,
		0xbe0eb4b9,
		0xbe348763,
		0xbdf9a3e5,
		0xbb8e277d,
		0x3dec795b,
		0x3e33a873,
		0x3e13ffad,
		0x3d1ea531,
		0xbdb272b6,
		0xbe2be210,
		0xbe257d59,
		0xbd92b6ae,
		0x3d63214d,
		0x3e1d80a0,
		0x3e309ef5,
		0x3dd07712,
		0xbcb1456a,
		0xbe0911c2,
		0xbe34f6fd,
		0xbe031a4e,
		0xbc550f7e,
		0x3ddebcd6,
		0x3e325ab0,
		0x3e18ef4e,
		0x3d411f1f,
		0xbda2c6e6,
		0xbe28e3c2,
	},
	{
		0x3e273d74,
		0x3d8a8bd4,
		0xbd8a8bd6,
		0xbe273d75,
		0xbe273d74,
		0xbd8a8bcc,
		0x3d8a8bd8,
		0x3e273d75,
		0x3e273d73,
		0x3d8a8bd0,
		0xbd8a8bdf,
		0xbe273d74,
		0xbe273d73,
		0xbd8a8bc9,
		0x3d8a8bd1,
		0x3e273d75,
		0x3e273d72,
		0x3d8a8bc1,
		0xbd8a8bd8,
		0xbe273d77,
		0xbe273d75,
		0xbd8a8bcf,
		0x3d8a8bdf,
		0x3e273d78,
		0x3e273d6f,
		0x3d8a8bb3,
		0xbd8a8bd1,
		0xbe273d75,
		0xbe273d72,
		0xbd8a8bc1,
		0x3d8a8bee,
		0x3e273d7b,
		0x3e273d75,
		0x3d8a8bcf,
		0xbd8a8be0,
		0xbe273d78,
		0xbe273d6f,
		0xbd8a8bb3,
		0x3d8a8bd2,
		0x3e273d75,
		0x3e273d72,
		0x3d8a8bc0,
		0xbd8a8bc4,
		0xbe273d7b,
		0xbe273d75,
		0xbd8a8ba4,
		0x3d8a8be0,
		0x3e273d81,
		0x3e273d6f,
		0x3d8a8bdc,
		0xbd8a8bfd,
		0xbe273d75,
		0xbe273d69,
		0xbd8a8bc0,
		0x3d8a8bc5,
		0x3e273d7b,
		0x3e273d75,
		0x3d8a8ba4,
		0xbd8a8be1,
		0xbe273d81,
		0xbe273d6f,
		0xbd8a8bdb,
		0x3d8a8bfd,
		0x3e273d75,
	},
}

// hamming_distance returns the number of differing bits between two 256-bit PDQ hashes.
hamming_distance :: proc(a, b: Hash) -> int {
	wa := transmute([4]u64)a
	wb := transmute([4]u64)b
	return int(
		intrinsics.count_ones(wa[0] ~ wb[0]) +
		intrinsics.count_ones(wa[1] ~ wb[1]) +
		intrinsics.count_ones(wa[2] ~ wb[2]) +
		intrinsics.count_ones(wa[3] ~ wb[3]),
	)
}

// rgba_to_luma converts packed RGBA8 pixels into row-major f32 luma (0..255),
// compositing alpha over black so transparent regions do not leak garbage RGB.
rgba_to_luma :: proc(rgba: [^]u8, width, height: int, out: []f32) {
	n := width * height
	assert(len(out) >= n)
	for i in 0 ..< n {
		p := i * 4
		r := f32(rgba[p + 0])
		g := f32(rgba[p + 1])
		b := f32(rgba[p + 2])
		a := rgba[p + 3]
		luma := r * LUMA_FROM_R_COEFF + g * LUMA_FROM_G_COEFF + b * LUMA_FROM_B_COEFF
		if a != 255 {
			luma *= f32(a) / 255.0
		}
		out[i] = luma
	}
}

// generate_pdq_rgba computes a 256-bit PDQ hash and 0..1 quality score from RGBA8 pixels.
generate_pdq_rgba :: proc(
	rgba: [^]u8,
	width, height: int,
	alloc := context.allocator,
) -> (
	hash: Hash,
	quality: f32,
	ok: bool,
) {
	if width < MIN_HASHABLE_DIM || height < MIN_HASHABLE_DIM {
		return {}, 0, false
	}
	n := width * height
	luma := make([]f32, n, alloc)
	defer delete(luma, alloc)
	scratch := make([]f32, n, alloc)
	defer delete(scratch, alloc)

	rgba_to_luma(rgba, width, height, luma)
	return generate_pdq_luma(luma, width, height, scratch)
}

// generate_pdq_luma computes PDQ in-place on luma (num_rows x num_cols, row-major).
// scratch must have length >= width * height.
generate_pdq_luma :: proc(
	luma: []f32,
	width, height: int,
	scratch: []f32,
) -> (
	hash: Hash,
	quality: f32,
	ok: bool,
) {
	if width < MIN_HASHABLE_DIM || height < MIN_HASHABLE_DIM {
		return {}, 0, false
	}
	n := width * height
	assert(len(luma) >= n && len(scratch) >= n)

	win_cols := compute_jarosz_filter_window_size(width, BUFFER_W_H)
	win_rows := compute_jarosz_filter_window_size(height, BUFFER_W_H)

	jarosz_filter_float(
		luma[:n],
		scratch[:n],
		height,
		width,
		win_cols,
		win_rows,
		PDQ_NUM_JAROSZ_XY_PASSES,
	)

	buf64 := decimate_64x64(luma[:n], height, width)
	dct16 := dct64_to_16(&buf64)
	return pdq_buffer16x16_to_bits(&dct16), pdq_image_domain_quality_metric(&buf64), true
}

@(private = "file")
compute_jarosz_filter_window_size :: proc(old_dim, new_dim: int) -> int {
	return (old_dim + 2 * new_dim - 1) / (2 * new_dim)
}

@(private = "file")
jarosz_filter_float :: proc(
	buf, tmp: []f32,
	num_rows, num_cols: int,
	win_along_rows, win_along_cols: int,
	nreps: int,
) {
	for _ in 0 ..< nreps {
		for i in 0 ..< num_rows {
			box_one_d_float(buf, i * num_cols, tmp, num_cols, 1, win_along_rows)
		}
		for j in 0 ..< num_cols {
			box_one_d_float(tmp, j, buf, num_rows, num_cols, win_along_cols)
		}
	}
}

@(private = "file")
box_one_d_float :: proc(
	invec: []f32,
	in_start_offset: int,
	outvec: []f32,
	vector_length: int,
	stride: int,
	full_window_size: int,
) {
	half_window_size := (full_window_size + 2) / 2
	phase_1_nreps := half_window_size - 1
	phase_2_nreps := full_window_size - half_window_size + 1

	oi_off := phase_1_nreps * stride
	li_off := phase_2_nreps * stride

	sum: f32 = 0
	current_window_size: f32 = 0

	phase_1_end := oi_off + in_start_offset
	for ri := in_start_offset; ri < phase_1_end; ri += stride {
		sum += invec[ri]
		current_window_size += 1
	}

	phase_2_end := full_window_size * stride + in_start_offset
	for ri := phase_1_end; ri < phase_2_end; ri += stride {
		oi := ri - oi_off
		sum += invec[ri]
		current_window_size += 1
		outvec[oi] = sum / current_window_size
	}

	phase_3_end := vector_length * stride + in_start_offset
	for ri := phase_2_end; ri < phase_3_end; ri += stride {
		oi := ri - oi_off
		li := oi - li_off
		sum += invec[ri]
		sum -= invec[li]
		outvec[oi] = sum / current_window_size
	}

	phase_4_start := (vector_length - half_window_size + 1) * stride + in_start_offset
	for oi := phase_4_start; oi < phase_3_end; oi += stride {
		li := oi - li_off
		sum -= invec[li]
		current_window_size -= 1
		outvec[oi] = sum / current_window_size
	}
}

@(private = "file")
decimate_64x64 :: proc(input: []f32, in_rows, in_cols: int) -> (out: [BUFFER_W_H][BUFFER_W_H]f32) {
	for outi in 0 ..< BUFFER_W_H {
		ini := ((outi * 2 + 1) * in_rows) / (BUFFER_W_H * 2)
		row_off := ini * in_cols
		for outj in 0 ..< BUFFER_W_H {
			inj := ((outj * 2 + 1) * in_cols) / (BUFFER_W_H * 2)
			out[outi][outj] = input[row_off + inj]
		}
	}
	return out
}

@(private = "file")
pdq_image_domain_quality_metric :: proc(buf: ^[BUFFER_W_H][BUFFER_W_H]f32) -> f32 {
	gradient_sum: f32 = 0
	for i in 0 ..< BUFFER_W_H - 1 {
		for j in 0 ..< BUFFER_W_H {
			d := (buf[i][j] - buf[i + 1][j]) / 255.0
			gradient_sum += abs(d)
		}
	}
	for i in 0 ..< BUFFER_W_H {
		for j in 0 ..< BUFFER_W_H - 1 {
			d := (buf[i][j] - buf[i][j + 1]) / 255.0
			gradient_sum += abs(d)
		}
	}
	q := gradient_sum / 90.0
	return q > 1.0 ? 1.0 : q
}

@(private = "file")
dct64_to_16 :: proc(input: ^[BUFFER_W_H][BUFFER_W_H]f32) -> (output: [DCT_OUTPUT_MATRIX_SIZE]f32) {
	inter: [DCT_OUTPUT_W_H][BUFFER_W_H]f32
	for i in 0 ..< DCT_OUTPUT_W_H {
		for j in 0 ..< BUFFER_W_H {
			sumk: f32 = 0
			for k in 0 ..< BUFFER_W_H {
				sumk += transmute(f32)DCT_MATRIX[i][k] * input[k][j]
			}
			inter[i][j] = sumk
		}
	}
	for i in 0 ..< DCT_OUTPUT_W_H {
		for j in 0 ..< DCT_OUTPUT_W_H {
			sumk: f32 = 0
			for k in 0 ..< BUFFER_W_H {
				sumk += inter[i][k] * transmute(f32)DCT_MATRIX[j][k]
			}
			output[i * DCT_OUTPUT_W_H + j] = sumk
		}
	}
	return output
}

@(private = "file")
torben_median :: proc(m: []f32) -> f32 {
	min_v := m[0]
	max_v := m[0]
	for v in m[1:] {
		if v < min_v {min_v = v}
		if v > max_v {max_v = v}
	}
	half := (len(m) + 1) / 2
	for {
		guess := (min_v + max_v) / 2.0
		less, greater, equal: int
		max_lt := min_v
		min_gt := max_v
		for val in m {
			if val < guess {
				less += 1
				if val > max_lt {max_lt = val}
			} else if val > guess {
				greater += 1
				if val < min_gt {min_gt = val}
			} else {
				equal += 1
			}
		}
		if less <= half && greater <= half {
			if less >= half {return max_lt}
			if less + equal >= half {return guess}
			return min_gt
		} else if less > greater {
			max_v = max_lt
		} else {
			min_v = min_gt
		}
	}
}

@(private = "file")
pdq_buffer16x16_to_bits :: proc(input: ^[DCT_OUTPUT_MATRIX_SIZE]f32) -> (hash: Hash) {
	med := torben_median(input[:])
	for i in 0 ..< HASH_LENGTH {
		b: u8
		for j in 0 ..< u8(8) {
			if input[i * 8 + int(j)] > med {
				b |= 1 << j
			}
		}
		hash[HASH_LENGTH - i - 1] = b
	}
	return hash
}
