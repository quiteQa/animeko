#import "ProbeSurfaceTexture.h"
#import <OpenGLES/EAGLIOSurface.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <TargetConditionals.h>

BOOL ProbeSurfaceTextureIsSupported(void) {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    return YES;
#endif
}

BOOL ProbeBindSurfaceTexture(EAGLContext *context, CVPixelBufferRef buffer) {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    if (!surface) return NO;
    return [context texImageIOSurface:surface
                              target:GL_TEXTURE_2D
                      internalFormat:GL_RGBA
                               width:(uint32_t)CVPixelBufferGetWidth(buffer)
                              height:(uint32_t)CVPixelBufferGetHeight(buffer)
                              format:GL_BGRA
                                type:GL_UNSIGNED_BYTE
                               plane:0];
#endif
}
