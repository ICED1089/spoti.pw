#import "SGArtistLogoMatte.h"
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdlib.h>

// Apple's artist wordmarks sometimes arrive flattened onto a white rectangle.
// Keep genuine RGBA assets unchanged. For a light grayscale/white-matted
// wordmark, create a neutral transparent mask so it blends with the hero.
// Unknown opaque/color art falls back to the accessible normal artist title.
UIImage *SGArtistLogoMatte(UIImage *source) {
    CGImageRef original = source.CGImage;
    if (!original) return nil;
    size_t width = CGImageGetWidth(original), height = CGImageGetHeight(original);
    if (!width || !height || width > 2048 || height > 2048 ||
        width > SIZE_MAX / 4 / height) return nil;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!space) return nil;
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8,
        width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), original);
    uint8_t *pixels = CGBitmapContextGetData(context);
    if (!pixels) { CGContextRelease(context); return nil; }

    size_t corners[4] = {0, width - 1, (height - 1) * width, width * height - 1};
    BOOL hasTransparency = NO, hasWhiteCorners = YES;
    for (unsigned i = 0; i < 4; ++i) {
        uint8_t *c = pixels + corners[i] * 4;
        if (c[3] < 200) hasTransparency = YES;
        if (c[3] < 245 || c[0] < 242 || c[1] < 242 || c[2] < 242)
            hasWhiteCorners = NO;
    }
    if (hasTransparency) { CGContextRelease(context); return source; }
    if (!hasWhiteCorners) { CGContextRelease(context); return nil; }

    size_t colored = 0, foreground = 0;
    for (size_t n = 0; n < width * height; n += 8) {
        uint8_t *p = pixels + n * 4;
        unsigned hi = MAX(p[0], MAX(p[1], p[2]));
        unsigned lo = MIN(p[0], MIN(p[1], p[2]));
        if (lo < 235) {
            ++foreground;
            if (hi - lo > 28) ++colored;
        }
    }
    if (!foreground) {
        CGContextRelease(context);
        return nil;
    }
    const BOOL coloredInk = colored * 20 > foreground;

    // Keep Apple's genuine coloured logo rather than silently repainting it white.
    // For a logo flattened onto white, recover premultiplied ink by removing the
    // white matte. A grey monochrome logo retains the old high-contrast white mask.
    for (size_t n = 0; n < width * height; ++n) {
        uint8_t *p = pixels + n * 4;
        if (coloredInk) {
            unsigned background = MIN(p[0], MIN(p[1], p[2]));
            unsigned ink = 255 - background;
            p[3] = (uint8_t)ink;
            p[0] = (uint8_t)(p[0] - background);
            p[1] = (uint8_t)(p[1] - background);
            p[2] = (uint8_t)(p[2] - background);
        } else {
            unsigned lum = (54 * p[0] + 183 * p[1] + 19 * p[2]) / 256;
            unsigned ink = lum >= 245 ? 0 : (245 - lum) * 255 / 55;
            if (ink > 255) ink = 255;
            p[3] = (uint8_t)ink;
            p[0] = p[1] = p[2] = (uint8_t)((245 * ink + 127) / 255);
        }
    }
    CGImageRef masked = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!masked) return nil;
    UIImage *prepared = [UIImage imageWithCGImage:masked
        scale:source.scale orientation:UIImageOrientationUp];
    CGImageRelease(masked);
    return prepared;
}
