import 'dart:async';

import 'package:flutter/services.dart';

class NativeSpeechEvent {
  const NativeSpeechEvent({
    required this.type,
    this.status,
    this.text,
    this.isFinal = false,
    this.confidence,
    this.code,
    this.message,
  });

  final String type;
  final String? status;
  final String? text;
  final bool isFinal;
  final double? confidence;
  final String? code;
  final String? message;

  factory NativeSpeechEvent.fromMap(Map<Object?, Object?> map) {
    return NativeSpeechEvent(
      type: (map['type'] ?? '').toString(),
      status: map['status']?.toString(),
      text: map['text']?.toString(),
      isFinal: map['isFinal'] == true,
      confidence: switch (map['confidence']) {
        final double v => v,
        final int v => v.toDouble(),
        final String v => double.tryParse(v),
        _ => null,
      },
      code: map['code']?.toString(),
      message: map['message']?.toString(),
    );
  }
}

class NativeSpeechService {
  NativeSpeechService._();

  static final NativeSpeechService instance = NativeSpeechService._();

  static const MethodChannel _methodChannel = MethodChannel(
    'quran_app/native_speech',
  );
  static const EventChannel _eventChannel = EventChannel(
    'quran_app/native_speech/events',
  );

  Stream<NativeSpeechEvent>? _events;

  Stream<NativeSpeechEvent> get events {
    _events ??= _eventChannel.receiveBroadcastStream().map((dynamic event) {
      final map = Map<Object?, Object?>.from(event as Map);
      return NativeSpeechEvent.fromMap(map);
    });
    return _events!;
  }

  Future<bool> isAvailable() async {
    final value = await _methodChannel.invokeMethod<bool>('isAvailable');
    return value ?? false;
  }

  Future<bool> hasPermission() async {
    final value = await _methodChannel.invokeMethod<bool>('hasPermission');
    return value ?? false;
  }

  Future<bool> requestPermission() async {
    final value = await _methodChannel.invokeMethod<bool>('requestPermission');
    return value ?? false;
  }

  Future<void> startListening({
    String locale = 'ar',
    bool partialResults = true,
    bool continuous = false,
  }) {
    return _methodChannel.invokeMethod<void>('startListening', {
      'locale': locale,
      'partialResults': partialResults,
      'continuous': continuous,
    });
  }

  Future<void> stopListening() {
    return _methodChannel.invokeMethod<void>('stopListening');
  }

  Future<void> cancelListening() {
    return _methodChannel.invokeMethod<void>('cancelListening');
  }
}
