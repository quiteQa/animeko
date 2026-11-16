#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL ProbeSurfaceTextureIsSupported(void);

/// Maps the pixel buffer's IOSurface into the currently bound GL_TEXTURE_2D.
FOUNDATION_EXPORT BOOL ProbeBindSurfaceTexture(EAGLContext *context, CVPixelBufferRef buffer);

NS_ASSUME_NONNULL_END
