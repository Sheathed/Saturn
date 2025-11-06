import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dart_blowfish/dart_blowfish.dart';

class DeezerDecryptor {
  /// Decrypts a file by reading it in chunks and decrypting every 3rd chunk of exactly 2048 bytes.
  static Future<void> decryptFile(
    String trackId,
    String inputFilename,
    String outputFilename,
  ) async {
    final inputFile = File(inputFilename);
    final outputFile = File(outputFilename);

    final inputStream = inputFile.openRead();
    final outputSink = outputFile.openWrite();

    final buffer = <int>[];
    int chunkCounter = 0;
    final key = getKey(trackId);

    await for (var chunk in inputStream) {
      buffer.addAll(chunk);

      // Process complete 2048-byte chunks
      while (buffer.length >= 2048) {
        final chunkData = buffer.sublist(0, 2048);
        buffer.removeRange(0, 2048);

        // Only every 3rd chunk of exactly 2048 bytes should be decrypted
        if (chunkCounter % 3 == 0) {
          final decrypted = decryptChunk(key, chunkData);
          outputSink.add(decrypted);
        } else {
          outputSink.add(chunkData);
        }
        chunkCounter++;
      }
    }

    // Write remaining bytes (less than 2048)
    if (buffer.isNotEmpty) {
      outputSink.add(buffer);
    }

    await outputSink.close();
  }

  /// Converts a byte array to a hexadecimal string.
  static String bytesToHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
  }

  /// Generates the Track decryption key based on the provided track ID and a secret.
  static List<int> getKey(String id) {
    const encodedSecret = 'ZzRlbDU4d2MwenZmOW5hMQ==';
    final secret = utf8.decode(base64.decode(encodedSecret));

    final md5Hash = md5.convert(utf8.encode(id));
    final idmd5 = bytesToHex(md5Hash.bytes).toLowerCase();

    final keyBuffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      final s0 = idmd5.codeUnitAt(i);
      final s1 = idmd5.codeUnitAt(i + 16);
      final s2 = secret.codeUnitAt(i);
      keyBuffer.writeCharCode(s0 ^ s1 ^ s2);
    }

    return utf8.encode(keyBuffer.toString());
  }

  /// Decrypts a 2048-byte chunk of data using the pre-initialized Blowfish cipher.
  static List<int> decryptChunk(List<int> key, List<int> data) {
    final Uint8List iv = Uint8List.fromList(const [
      00,
      01,
      02,
      03,
      04,
      05,
      06,
      07,
    ]);
    final bf = Blowfish(
      key: Uint8List.fromList(key),
      mode: Mode.cbc,
      padding: Padding.none,
    )..setIv(iv);
    Uint8List decrypted = bf.decode(data, returnType: Type.uInt8Array);
    return decrypted;
  }
}
