import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:native_core/native_core.dart' show JxlImage, decodeJxl, freeJxlPixels, isJxl;

part 'local_image_request.dart';
part 'remote_image_request.dart';
part 'thumbhash_image_request.dart';

abstract class ImageRequest {
  static int _nextRequestId = 0;

  final int requestId = _nextRequestId++;
  bool _isCancelled = false;

  // ignore: unused-code
  bool get isCancelled => _isCancelled;

  ImageRequest();

  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0});

  Future<ui.Codec?> loadCodec();

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    return _onCancelled();
  }

  void _onCancelled();

  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromEncodedPlatformImage(
    int address,
    int length, {
    ui.Size? decodeSize,
  }) async {
    final pointer = Pointer<Uint8>.fromAddress(address);
    if (_isCancelled) {
      malloc.free(pointer);
      return null;
    }

    if (isJxl(address, length)) {
      return _codecFromJxl(pointer, length, decodeSize: decodeSize);
    }

    final ui.ImmutableBuffer buffer;
    try {
      buffer = await ImmutableBuffer.fromUint8List(pointer.asTypedList(length));
    } finally {
      malloc.free(pointer);
    }

    if (_isCancelled) {
      buffer.dispose();
      return null;
    }

    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    if (_isCancelled) {
      descriptor.dispose();
      return null;
    }

    final target = _targetSize(descriptor.width, descriptor.height, decodeSize);
    final codec = await descriptor.instantiateCodec(targetWidth: target?.$1, targetHeight: target?.$2);
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }

    return (codec, descriptor);
  }

  // Flutter cannot decode JPEG XL, and the platform decoders only can on some OS versions.
  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromJxl(
    Pointer<Uint8> pointer,
    int length, {
    ui.Size? decodeSize,
  }) async {
    final image = await _decodeJxl(pointer.address, length).whenComplete(() => malloc.free(pointer));
    if (image == null) {
      throw const FormatException('Could not decode JPEG XL image');
    }

    if (_isCancelled) {
      freeJxlPixels(image);
      return null;
    }

    return _codecFromPixels(
      Pointer<Uint8>.fromAddress(image.address),
      width: image.width,
      height: image.height,
      rowBytes: image.rowBytes,
      free: () => freeJxlPixels(image),
      decodeSize: decodeSize,
    );
  }

  // Static, so the closure sent to the isolate cannot capture the request.
  static Future<JxlImage?> _decodeJxl(int address, int length) => Isolate.run(() => decodeJxl(address, length));

  Future<ui.FrameInfo?> _fromEncodedPlatformImage(int address, int length, {ui.Size? decodeSize}) async {
    final result = await _codecFromEncodedPlatformImage(address, length, decodeSize: decodeSize);
    return _firstFrame(result);
  }

  Future<ui.FrameInfo?> _firstFrame((ui.Codec, ui.ImageDescriptor)? result) async {
    if (result == null) {
      return null;
    }

    final (codec, descriptor) = result;
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }

    final frame = await codec.getNextFrame();
    descriptor.dispose();
    codec.dispose();
    if (_isCancelled) {
      frame.image.dispose();
      return null;
    }

    return frame;
  }

  (int, int)? _targetSize(int width, int height, ui.Size? decodeSize) {
    if (width <= 0 || height <= 0 || decodeSize == null || decodeSize.width <= 0 || decodeSize.height <= 0) {
      return null;
    }

    final scale = math.max(decodeSize.width / width, decodeSize.height / height);
    if (scale >= 1) {
      return null;
    }

    return ((width * scale).ceil(), (height * scale).ceil());
  }

  Future<ui.FrameInfo?> _fromDecodedPlatformImage(int address, int width, int height, int rowBytes) async {
    final pointer = Pointer<Uint8>.fromAddress(address);
    if (_isCancelled) {
      malloc.free(pointer);
      return null;
    }

    final result = await _codecFromPixels(
      pointer,
      width: width,
      height: height,
      rowBytes: rowBytes,
      free: () => malloc.free(pointer),
    );
    return _firstFrame(result);
  }

  /// Wraps premultiplied RGBA [pixels] in a codec, calling [free] once they are copied.
  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromPixels(
    Pointer<Uint8> pixels, {
    required int width,
    required int height,
    required int rowBytes,
    required void Function() free,
    ui.Size? decodeSize,
  }) async {
    final ui.ImmutableBuffer buffer;
    try {
      buffer = await ImmutableBuffer.fromUint8List(pixels.asTypedList(rowBytes * height));
    } finally {
      free();
    }

    if (_isCancelled) {
      buffer.dispose();
      return null;
    }

    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      rowBytes: rowBytes,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    buffer.dispose();

    final target = _targetSize(width, height, decodeSize);
    final codec = await descriptor.instantiateCodec(targetWidth: target?.$1, targetHeight: target?.$2);
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }

    return (codec, descriptor);
  }
}
