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
    final key = await getKey(trackId);
    final decryptor = DeezerChunkDecryptor(key);

    await for (var chunk in inputStream) {
      buffer.addAll(chunk);

      // Process complete 2048-byte chunks
      while (buffer.length >= 2048) {
        final chunkData = buffer.sublist(0, 2048);
        buffer.removeRange(0, 2048);

        // Only every 3rd chunk of exactly 2048 bytes should be decrypted
        if (chunkCounter % 3 == 0) {
          final decrypted = decryptor.decrypt(chunkData);
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

  static String? _cachedSecret;

  static Future<String> _fetchSecret() async {
    if (_cachedSecret != null) return _cachedSecret!;

    try {
      final htmlClient = HttpClient();
      final htmlReq = await htmlClient.getUrl(Uri.parse('https://www.deezer.com/en/channels/explore'));
      final htmlRes = await htmlReq.close();
      final htmlStr = await htmlRes.transform(utf8.decoder).join();
      
      final jsUrlMatch = RegExp(r'src="([^"]*app-web[^"]*)"').firstMatch(htmlStr);
      if (jsUrlMatch == null) throw Exception('Could not find app-web.js url');
      
      String jsUrl = jsUrlMatch.group(1)!;
      if (!jsUrl.startsWith('http')) jsUrl = 'https:' + (jsUrl.startsWith('//') ? jsUrl : '//' + jsUrl);

      final jsReq = await htmlClient.getUrl(Uri.parse(jsUrl));
      final jsRes = await jsReq.close();
      final jsStr = await jsRes.transform(utf8.decoder).join();
      
      final hexRegex = RegExp(r'%5B0x[0-9a-fA-F]{1,2}(?:%2C0x[0-9a-fA-F]{1,2}){7}%5D');
      final matches = hexRegex.allMatches(jsStr).toList();
      
      if (matches.length < 2) throw Exception('Could not find enough arrays in app-web.js');
      
      final List<int> combinedHex = [];
      for (int i = 0; i < 2; i++) {
        final matchStr = matches[i].group(0)!;
        final decoded = Uri.decodeComponent(matchStr);
        final hexValues = decoded.replaceAll('[', '').replaceAll(']', '').split(',');
        for (var hex in hexValues) {
          combinedHex.add(int.parse(hex.trim().replaceFirst('0x', ''), radix: 16));
        }
      }
      
      if (combinedHex.length != 16) throw Exception('Invalid array length extracted');
      
      final List<int> unscrambleIdx = [7, 15, 6, 14, 5, 13, 4, 12, 3, 11, 2, 10, 1, 9, 0, 8];
      final unscrambled = List<int>.filled(16, 0);
      for (int i = 0; i < 16; i++) {
        unscrambled[i] = combinedHex[unscrambleIdx[i]];
      }
      
      _cachedSecret = String.fromCharCodes(unscrambled);
    } catch (e) {
      // Fallback to the known secret if network extraction fails
      _cachedSecret = utf8.decode(base64.decode('ZzRlbDU4d2MwenZmOW5hMQ=='));
    }
    return _cachedSecret!;
  }

  /// Generates the Track decryption key based on the provided track ID and a secret.
  static Future<List<int>> getKey(String id) async {
    final secretStr = await _fetchSecret();
    final md5Hash = md5.convert(utf8.encode(id));
    final idmd5 = bytesToHex(md5Hash.bytes).toLowerCase();

    final keyBuffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      final s0 = idmd5.codeUnitAt(i);
      final s1 = idmd5.codeUnitAt(i + 16);
      final s2 = secretStr.codeUnitAt(i);
      keyBuffer.writeCharCode(s0 ^ s1 ^ s2);
    }

    return utf8.encode(keyBuffer.toString());
  }

  /// Decrypts a 2048-byte chunk of data using the pre-initialized Blowfish cipher.
  static List<int> decryptChunk(List<int> key, List<int> data) {
    return DeezerChunkDecryptor(key).decrypt(data);
  }
}

/// Reuses Blowfish's expanded key schedule while decrypting a single stream.
/// Deezer's encrypted stripes each restart CBC with the same IV; the package's
/// decoder treats the IV as input and does not mutate it, so the cipher can be
/// reused safely across independent 2048-byte stripes.
class DeezerChunkDecryptor {
  static final Uint8List _iv = Uint8List.fromList(const [
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
  ]);

  final Blowfish _cipher;

  DeezerChunkDecryptor(List<int> key)
    : _cipher = Blowfish(
        key: Uint8List.fromList(key),
        mode: Mode.cbc,
        padding: Padding.none,
      )..setIv(_iv);

  Uint8List decrypt(List<int> data) =>
      _cipher.decode(data, returnType: Type.uInt8Array) as Uint8List;
}
