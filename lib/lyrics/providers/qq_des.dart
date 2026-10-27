import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pure Dart implementation of QQ Music modified DES and 3DES algorithm.
/// Based on QQMusicDES from LyricDecoder.
class QQMusicDes {
  static const List<int> qqKey = [
    0x21, 0x40, 0x23, 0x29, 0x28, 0x2A, 0x24, 0x25,
    0x31, 0x32, 0x33, 0x5A, 0x58, 0x43, 0x21, 0x40,
    0x21, 0x40, 0x23, 0x29, 0x28, 0x4E, 0x48, 0x4C
  ];

  static int _bitnum(List<int> a, int b, int c) {
    final idx = (b ~/ 32) * 4 + 3 - (b % 32) ~/ 8;
    return (((a[idx] >> (7 - (b % 8))) & 0x01) << c) & 0xFFFFFFFF;
  }

  static int _bitnumintr(int a, int b, int c) {
    return ((((a >>> (31 - b))) & 0x01) << c) & 0xFFFFFFFF;
  }

  static int _bitnumintl(int a, int b, int c) {
    return ((((a << b) & 0x80000000) >>> c)) & 0xFFFFFFFF;
  }

  static int _sboxbit(int a) {
    return ((a & 0x20) | ((a & 0x1f) >> 1) | ((a & 0x01) << 4)) & 0xFF;
  }

  static const List<int> _sbox1 = [
    14,  4, 13,  1,  2, 15, 11,  8,  3, 10,  6, 12,  5,  9,  0,  7,
     0, 15,  7,  4, 14,  2, 13,  1, 10,  6, 12, 11,  9,  5,  3,  8,
     4,  1, 14,  8, 13,  6,  2, 11, 15, 12,  9,  7,  3, 10,  5,  0,
    15, 12,  8,  2,  4,  9,  1,  7,  5, 11,  3, 14, 10,  0,  6, 13
  ];
  static const List<int> _sbox2 = [
    15,  1,  8, 14,  6, 11,  3,  4,  9,  7,  2, 13, 12,  0,  5, 10,
     3, 13,  4,  7, 15,  2,  8, 15, 12,  0,  1, 10,  6,  9, 11,  5,
     0, 14,  7, 11, 10,  4, 13,  1,  5,  8, 12,  6,  9,  3,  2, 15,
    13,  8, 10,  1,  3, 15,  4,  2, 11,  6,  7, 12,  0,  5, 14,  9
  ];
  static const List<int> _sbox3 = [
    10,  0,  9, 14,  6,  3, 15,  5,  1, 13, 12,  7, 11,  4,  2,  8,
    13,  7,  0,  9,  3,  4,  6, 10,  2,  8,  5, 14, 12, 11, 15,  1,
    13,  6,  4,  9,  8, 15,  3,  0, 11,  1,  2, 12,  5, 10, 14,  7,
     1, 10, 13,  0,  6,  9,  8,  7,  4, 15, 14,  3, 11,  5,  2, 12
  ];
  static const List<int> _sbox4 = [
     7, 13, 14,  3,  0,  6,  9, 10,  1,  2,  8,  5, 11, 12,  4, 15,
    13,  8, 11,  5,  6, 15,  0,  3,  4,  7,  2, 12,  1, 10, 14,  9,
    10,  6,  9,  0, 12, 11,  7, 13, 15,  1,  3, 14,  5,  2,  8,  4,
     3, 15,  0,  6, 10, 10, 13,  8,  9,  4,  5, 11, 12,  7,  2, 14
  ];
  static const List<int> _sbox5 = [
     2, 12,  4,  1,  7, 10, 11,  6,  8,  5,  3, 15, 13,  0, 14,  9,
    14, 11,  2, 12,  4,  7, 13,  1,  5,  0, 15, 10,  3,  9,  8,  6,
     4,  2,  1, 11, 10, 13,  7,  8, 15,  9, 12,  5,  6,  3,  0, 14,
    11,  8, 12,  7,  1, 14,  2, 13,  6, 15,  0,  9, 10,  4,  5,  3
  ];
  static const List<int> _sbox6 = [
    12,  1, 10, 15,  9,  2,  6,  8,  0, 13,  3,  4, 14,  7,  5, 11,
    10, 15,  4,  2,  7, 12,  9,  5,  6,  1, 13, 14,  0, 11,  3,  8,
     9, 14, 15,  5,  2,  8, 12,  3,  7,  0,  4, 10,  1, 13, 11,  6,
     4,  3,  2, 12,  9,  5, 15, 10, 11, 14,  1,  7,  6,  0,  8, 13
  ];
  static const List<int> _sbox7 = [
     4, 11,  2, 14, 15,  0,  8, 13,  3, 12,  9,  7,  5, 10,  6,  1,
    13,  0, 11,  7,  4,  9,  1, 10, 14,  3,  5, 12,  2, 15,  8,  6,
     1,  4, 11, 13, 12,  3,  7, 14, 10, 15,  6,  8,  0,  5,  9,  2,
     6, 11, 13,  8,  1,  4, 10,  7,  9,  5,  0, 15, 14,  2,  3, 12
  ];
  static const List<int> _sbox8 = [
    13,  2,  8,  4,  6, 15, 11,  1, 10,  9,  3, 14,  5,  0, 12,  7,
     1, 15, 13,  8, 10,  3,  7,  4, 12,  5,  6, 11,  0, 14,  9,  2,
     7, 11,  4,  1,  9, 12, 14,  2,  0,  6, 10, 13, 15,  3,  5,  8,
     2,  1, 14,  7,  4, 10,  8, 13, 15, 12,  9,  0,  3,  5,  6, 11
  ];

  static void _ip(List<int> state, List<int> inp, int inOffset) {
    final inBytes = inp.sublist(inOffset, inOffset + 8);
    state[0] = _bitnum(inBytes, 57, 31) | _bitnum(inBytes, 49, 30) | _bitnum(inBytes, 41, 29) | _bitnum(inBytes, 33, 28) |
               _bitnum(inBytes, 25, 27) | _bitnum(inBytes, 17, 26) | _bitnum(inBytes, 9, 25)  | _bitnum(inBytes, 1, 24)  |
               _bitnum(inBytes, 59, 23) | _bitnum(inBytes, 51, 22) | _bitnum(inBytes, 43, 21) | _bitnum(inBytes, 35, 20) |
               _bitnum(inBytes, 27, 19) | _bitnum(inBytes, 19, 18) | _bitnum(inBytes, 11, 17) | _bitnum(inBytes, 3, 16)  |
               _bitnum(inBytes, 61, 15) | _bitnum(inBytes, 53, 14) | _bitnum(inBytes, 45, 13) | _bitnum(inBytes, 37, 12) |
               _bitnum(inBytes, 29, 11) | _bitnum(inBytes, 21, 10) | _bitnum(inBytes, 13, 9)  | _bitnum(inBytes, 5, 8)   |
               _bitnum(inBytes, 63, 7)  | _bitnum(inBytes, 55, 6)  | _bitnum(inBytes, 47, 5)  | _bitnum(inBytes, 39, 4)  |
               _bitnum(inBytes, 31, 3)  | _bitnum(inBytes, 23, 2)  | _bitnum(inBytes, 15, 1)  | _bitnum(inBytes, 7, 0);

    state[1] = _bitnum(inBytes, 56, 31) | _bitnum(inBytes, 48, 30) | _bitnum(inBytes, 40, 29) | _bitnum(inBytes, 32, 28) |
               _bitnum(inBytes, 24, 27) | _bitnum(inBytes, 16, 26) | _bitnum(inBytes, 8, 25)  | _bitnum(inBytes, 0, 24)  |
               _bitnum(inBytes, 58, 23) | _bitnum(inBytes, 50, 22) | _bitnum(inBytes, 42, 21) | _bitnum(inBytes, 34, 20) |
               _bitnum(inBytes, 26, 19) | _bitnum(inBytes, 18, 18) | _bitnum(inBytes, 10, 17) | _bitnum(inBytes, 2, 16)  |
               _bitnum(inBytes, 60, 15) | _bitnum(inBytes, 52, 14) | _bitnum(inBytes, 44, 13) | _bitnum(inBytes, 36, 12) |
               _bitnum(inBytes, 28, 11) | _bitnum(inBytes, 20, 10) | _bitnum(inBytes, 12, 9)  | _bitnum(inBytes, 4, 8)   |
               _bitnum(inBytes, 62, 7)  | _bitnum(inBytes, 54, 6)  | _bitnum(inBytes, 46, 5)  | _bitnum(inBytes, 38, 4)  |
               _bitnum(inBytes, 30, 3)  | _bitnum(inBytes, 22, 2)  | _bitnum(inBytes, 14, 1)  | _bitnum(inBytes, 6, 0);
  }

  static void _invIp(List<int> state, List<int> outBytes, int outOffset) {
    outBytes[outOffset + 3] = (_bitnumintr(state[1], 7, 7)  | _bitnumintr(state[0], 7, 6)  | _bitnumintr(state[1], 15, 5) |
                               _bitnumintr(state[0], 15, 4) | _bitnumintr(state[1], 23, 3) | _bitnumintr(state[0], 23, 2) |
                               _bitnumintr(state[1], 31, 1) | _bitnumintr(state[0], 31, 0)) & 0xFF;

    outBytes[outOffset + 2] = (_bitnumintr(state[1], 6, 7)  | _bitnumintr(state[0], 6, 6)  | _bitnumintr(state[1], 14, 5) |
                               _bitnumintr(state[0], 14, 4) | _bitnumintr(state[1], 22, 3) | _bitnumintr(state[0], 22, 2) |
                               _bitnumintr(state[1], 30, 1) | _bitnumintr(state[0], 30, 0)) & 0xFF;

    outBytes[outOffset + 1] = (_bitnumintr(state[1], 5, 7)  | _bitnumintr(state[0], 5, 6)  | _bitnumintr(state[1], 13, 5) |
                               _bitnumintr(state[0], 13, 4) | _bitnumintr(state[1], 21, 3) | _bitnumintr(state[0], 21, 2) |
                               _bitnumintr(state[1], 29, 1) | _bitnumintr(state[0], 29, 0)) & 0xFF;

    outBytes[outOffset + 0] = (_bitnumintr(state[1], 4, 7)  | _bitnumintr(state[0], 4, 6)  | _bitnumintr(state[1], 12, 5) |
                               _bitnumintr(state[0], 12, 4) | _bitnumintr(state[1], 20, 3) | _bitnumintr(state[0], 20, 2) |
                               _bitnumintr(state[1], 28, 1) | _bitnumintr(state[0], 28, 0)) & 0xFF;

    outBytes[outOffset + 7] = (_bitnumintr(state[1], 3, 7)  | _bitnumintr(state[0], 3, 6)  | _bitnumintr(state[1], 11, 5) |
                               _bitnumintr(state[0], 11, 4) | _bitnumintr(state[1], 19, 3) | _bitnumintr(state[0], 19, 2) |
                               _bitnumintr(state[1], 27, 1) | _bitnumintr(state[0], 27, 0)) & 0xFF;

    outBytes[outOffset + 6] = (_bitnumintr(state[1], 2, 7)  | _bitnumintr(state[0], 2, 6)  | _bitnumintr(state[1], 10, 5) |
                               _bitnumintr(state[0], 10, 4) | _bitnumintr(state[1], 18, 3) | _bitnumintr(state[0], 18, 2) |
                               _bitnumintr(state[1], 26, 1) | _bitnumintr(state[0], 26, 0)) & 0xFF;

    outBytes[outOffset + 5] = (_bitnumintr(state[1], 1, 7)  | _bitnumintr(state[0], 1, 6)  | _bitnumintr(state[1], 9, 5)  |
                               _bitnumintr(state[0], 9, 4)  | _bitnumintr(state[1], 17, 3) | _bitnumintr(state[0], 17, 2) |
                               _bitnumintr(state[1], 25, 1) | _bitnumintr(state[0], 25, 0)) & 0xFF;

    outBytes[outOffset + 4] = (_bitnumintr(state[1], 0, 7)  | _bitnumintr(state[0], 0, 6)  | _bitnumintr(state[1], 8, 5)  |
                               _bitnumintr(state[0], 8, 4)  | _bitnumintr(state[1], 16, 3) | _bitnumintr(state[0], 16, 2) |
                               _bitnumintr(state[1], 24, 1) | _bitnumintr(state[0], 24, 0)) & 0xFF;
  }

  static int _f(int state, List<int> key) {
    int t1 = _bitnumintl(state, 31, 0) | ((state & 0xf0000000) >>> 1) | _bitnumintl(state, 4, 5)   |
             _bitnumintl(state, 3, 6)  | ((state & 0x0f000000) >>> 3) | _bitnumintl(state, 8, 11)  |
             _bitnumintl(state, 7, 12) | ((state & 0x00f00000) >>> 5) | _bitnumintl(state, 12, 17) |
             _bitnumintl(state, 11, 18)| ((state & 0x000f0000) >>> 7) | _bitnumintl(state, 16, 23);

    int t2 = _bitnumintl(state, 15, 0) | ((state & 0x0000f000) << 15) | _bitnumintl(state, 20, 5)  |
             _bitnumintl(state, 19, 6) | ((state & 0x00000f00) << 13) | _bitnumintl(state, 24, 11) |
             _bitnumintl(state, 23, 12)| ((state & 0x000000f0) << 11) | _bitnumintl(state, 28, 17) |
             _bitnumintl(state, 27, 18)| ((state & 0x0000000f) << 9)  | _bitnumintl(state, 0, 23);

    final lrgstate = List<int>.filled(6, 0);
    lrgstate[0] = (t1 >>> 24) & 0xff;
    lrgstate[1] = (t1 >>> 16) & 0xff;
    lrgstate[2] = (t1 >>> 8) & 0xff;
    lrgstate[3] = (t2 >>> 24) & 0xff;
    lrgstate[4] = (t2 >>> 16) & 0xff;
    lrgstate[5] = (t2 >>> 8) & 0xff;

    for (int i = 0; i < 6; i++) {
      lrgstate[i] ^= key[i];
    }

    int res = (_sbox1[_sboxbit(lrgstate[0] >> 2)] << 28) |
              (_sbox2[_sboxbit(((lrgstate[0] & 0x03) << 4) | (lrgstate[1] >> 4))] << 24) |
              (_sbox3[_sboxbit(((lrgstate[1] & 0x0f) << 2) | (lrgstate[2] >> 6))] << 20) |
              (_sbox4[_sboxbit(lrgstate[2] & 0x3f)] << 16) |
              (_sbox5[_sboxbit(lrgstate[3] >> 2)] << 12) |
              (_sbox6[_sboxbit(((lrgstate[3] & 0x03) << 4) | (lrgstate[4] >> 4))] << 8) |
              (_sbox7[_sboxbit(((lrgstate[4] & 0x0f) << 2) | (lrgstate[5] >> 6))] << 4) |
               _sbox8[_sboxbit(lrgstate[5] & 0x3f)];

    res = _bitnumintl(res, 15, 0)  | _bitnumintl(res, 6, 1)   | _bitnumintl(res, 19, 2)  |
          _bitnumintl(res, 20, 3)  | _bitnumintl(res, 28, 4)  | _bitnumintl(res, 11, 5)  |
          _bitnumintl(res, 27, 6)  | _bitnumintl(res, 16, 7)  | _bitnumintl(res, 0, 8)   |
          _bitnumintl(res, 14, 9)  | _bitnumintl(res, 22, 10) | _bitnumintl(res, 25, 11) |
          _bitnumintl(res, 4, 12)  | _bitnumintl(res, 17, 13) | _bitnumintl(res, 30, 14) |
          _bitnumintl(res, 9, 15)  | _bitnumintl(res, 1, 16)  | _bitnumintl(res, 7, 17)  |
          _bitnumintl(res, 23, 18) | _bitnumintl(res, 13, 19) | _bitnumintl(res, 31, 20) |
          _bitnumintl(res, 26, 21) | _bitnumintl(res, 2, 22)  | _bitnumintl(res, 8, 23)  |
          _bitnumintl(res, 18, 24) | _bitnumintl(res, 12, 25) | _bitnumintl(res, 29, 26) |
          _bitnumintl(res, 5, 27)  | _bitnumintl(res, 21, 28) | _bitnumintl(res, 10, 29) |
          _bitnumintl(res, 3, 30)  | _bitnumintl(res, 24, 31);

    return res & 0xFFFFFFFF;
  }

  static const List<int> _keyRndShift = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
  static const List<int> _keyPermC = [
    56,48,40,32,24,16,8,0,57,49,41,33,25,17,
    9,1,58,50,42,34,26,18,10,2,59,51,43,35
  ];
  static const List<int> _keyPermD = [
    62,54,46,38,30,22,14,6,61,53,45,37,29,21,
    13,5,60,52,44,36,28,20,12,4,27,19,11,3
  ];
  static const List<int> _keyCompression = [
    13,16,10,23,0,4,2,27,14,5,20,9,
    22,18,11,3,25,7,15,6,26,19,12,1,
    40,51,30,36,46,54,29,39,50,44,32,47,
    43,48,38,55,33,52,45,41,49,35,28,31
  ];

  static void _desKeySetup(List<int> key, int keyOffset, List<List<int>> schedule, bool decrypt) {
    int c = 0, d = 0;
    final keyBytes = key.sublist(keyOffset, keyOffset + 8);
    for (int i = 0, j = 31; i < 28; ++i, --j) {
      c |= _bitnum(keyBytes, _keyPermC[i], j);
      d |= _bitnum(keyBytes, _keyPermD[i], j);
    }

    for (int i = 0; i < 16; ++i) {
      c = (((c << _keyRndShift[i]) | (c >>> (28 - _keyRndShift[i]))) & 0xfffffff0) & 0xFFFFFFFF;
      d = (((d << _keyRndShift[i]) | (d >>> (28 - _keyRndShift[i]))) & 0xfffffff0) & 0xFFFFFFFF;

      final toGen = decrypt ? 15 - i : i;
      for (int j = 0; j < 6; ++j) {
        schedule[toGen][j] = 0;
      }
      for (int j = 0; j < 24; ++j) {
        schedule[toGen][j ~/ 8] |= _bitnumintr(c, _keyCompression[j], 7 - (j % 8));
      }
      for (int j = 24; j < 48; ++j) {
        schedule[toGen][j ~/ 8] |= _bitnumintr(d, _keyCompression[j] - 27, 7 - (j % 8));
      }
    }
  }

  static void _desCrypt(List<int> inp, int inOffset, List<int> outBytes, int outOffset, List<List<int>> keySched) {
    final state = [0, 0];
    _ip(state, inp, inOffset);

    for (int idx = 0; idx < 15; ++idx) {
      final t = state[1];
      state[1] = (_f(state[1], keySched[idx]) ^ state[0]) & 0xFFFFFFFF;
      state[0] = t;
    }
    state[0] = (_f(state[1], keySched[15]) ^ state[0]) & 0xFFFFFFFF;

    _invIp(state, outBytes, outOffset);
  }

  static List<List<List<int>>> _createThreeDesSchedule(List<int> key, bool decrypt) {
    final schedule = List.generate(3, (_) => List.generate(16, (_) => List<int>.filled(6, 0)));
    if (!decrypt) {
      _desKeySetup(key, 0, schedule[0], false);
      _desKeySetup(key, 8, schedule[1], true);
      _desKeySetup(key, 16, schedule[2], false);
    } else {
      _desKeySetup(key, 16, schedule[0], true);
      _desKeySetup(key, 8, schedule[1], false);
      _desKeySetup(key, 0, schedule[2], true);
    }
    return schedule;
  }

  static void _threeDesCrypt(List<int> inp, int inOffset, List<int> outBytes, int outOffset, List<List<List<int>>> schedule) {
    final temp1 = List<int>.filled(8, 0);
    final temp2 = List<int>.filled(8, 0);

    _desCrypt(inp, inOffset, temp1, 0, schedule[0]);
    _desCrypt(temp1, 0, temp2, 0, schedule[1]);
    _desCrypt(temp2, 0, outBytes, outOffset, schedule[2]);
  }

  /// Decrypt QRC bytes (after "[offset:0]\n" header or raw hex decoded bytes).
  static String? decryptQrc(Uint8List rawBytes) {
    try {
      final schedule = _createThreeDesSchedule(qqKey, true);
      final decrypted = Uint8List.fromList(rawBytes);

      for (int i = 0; i + 8 <= decrypted.length; i += 8) {
        _threeDesCrypt(decrypted, i, decrypted, i, schedule);
      }

      final decompressed = zlib.decode(decrypted);
      return utf8.decode(decompressed, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
