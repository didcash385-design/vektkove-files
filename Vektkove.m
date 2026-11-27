#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import <ModelIO/ModelIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <float.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#import "VKEngine.h"
#define VEKTKOVE_MINI3D
#include "third_party/mini3d/mini3d.c"

static NSString *const VKLicenseText = @"Copyright (c) 2026 VCCcash\n\n"
    @"Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    @"of this software and associated documentation files (the \"Software\"), to deal\n"
    @"in the Software without restriction, including without limitation the rights\n"
    @"to use, copy, modify, merge, publish, distribute, sublicense, and/or sell\n"
    @"copies of the Software, and to permit persons to whom the Software is\n"
    @"furnished to do so, subject to the following conditions:\n\n"
    @"The above copyright notice and this permission notice shall be included in all\n"
    @"copies or substantial portions of the Software.\n\n"
    @"THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\n"
    @"IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\n"
    @"FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\n"
    @"AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\n"
    @"LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\n"
    @"OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\n"
    @"SOFTWARE.";

@interface VKBackgroundView : NSView
@end
@implementation VKBackgroundView
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirtyRect);
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

static void drawVektkoveBrandMark(NSRect bounds) {
    CGFloat scale = MIN(bounds.size.width, bounds.size.height) / 36;
    BOOL flipped = NSGraphicsContext.currentContext.isFlipped;
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:bounds.origin.x yBy:flipped ? bounds.origin.y : NSMaxY(bounds)];
    [transform scaleXBy:scale yBy:flipped ? scale : -scale];
    [transform concat];
    [[NSColor colorWithSRGBRed:0.08 green:0.12 blue:0.17 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, 36, 36) xRadius:8 yRadius:8] fill];
    NSBezierPath *top = [NSBezierPath bezierPath];
    [top moveToPoint:NSMakePoint(18, 5)]; [top lineToPoint:NSMakePoint(30, 12)];
    [top lineToPoint:NSMakePoint(18, 19)]; [top lineToPoint:NSMakePoint(6, 12)]; [top closePath];
    [[NSColor colorWithSRGBRed:0.20 green:0.82 blue:0.77 alpha:1] setFill]; [top fill];
    NSBezierPath *left = [NSBezierPath bezierPath];
    [left moveToPoint:NSMakePoint(6, 12)]; [left lineToPoint:NSMakePoint(18, 19)];
    [left lineToPoint:NSMakePoint(18, 31)]; [left lineToPoint:NSMakePoint(6, 24)]; [left closePath];
    [[NSColor colorWithSRGBRed:0.96 green:0.42 blue:0.29 alpha:1] setFill]; [left fill];
    NSBezierPath *right = [NSBezierPath bezierPath];
    [right moveToPoint:NSMakePoint(30, 12)]; [right lineToPoint:NSMakePoint(18, 19)];
    [right lineToPoint:NSMakePoint(18, 31)]; [right lineToPoint:NSMakePoint(30, 24)]; [right closePath];
    [[NSColor colorWithSRGBRed:0.30 green:0.60 blue:0.88 alpha:1] setFill]; [right fill];
    [NSGraphicsContext restoreGraphicsState];
}

static NSImage *vektkoveDockIcon(void) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(512, 512)];
    [image lockFocus];
    drawVektkoveBrandMark(NSMakeRect(0, 0, 512, 512));
    [image unlockFocus];
    return image;
}

@interface VKBrandMarkView : NSView
@end
@implementation VKBrandMarkView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    drawVektkoveBrandMark(self.bounds);
}
@end

@interface VKCanvas : VKBackgroundView
@end
@implementation VKCanvas
- (BOOL)isFlipped { return YES; }
@end

static NSColor *colorFromHex(NSString *hex) {
    if (hex.length != 7 || ![hex hasPrefix:@"#"]) return NSColor.controlBackgroundColor;
    unsigned value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return NSColor.controlBackgroundColor;
    return [NSColor colorWithSRGBRed:((value >> 16) & 255) / 255.0 green:((value >> 8) & 255) / 255.0 blue:(value & 255) / 255.0 alpha:1];
}

static NSColor *textColorForBackground(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return (0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent) > 0.6 ? NSColor.blackColor : NSColor.whiteColor;
}

@interface VKDesignerCanvas : VKCanvas
@property (strong) NSMutableArray<NSMutableDictionary *> *elements;
@property NSSize documentSize;
@property NSInteger selectedIndex;
@property NSInteger dragIndex;
@property NSPoint dragStart;
@property NSRect startFrame;
@property BOOL resizing;
@property BOOL showsGrid;
@property BOOL snapsToGrid;
@property CGFloat gridSize;
@property (copy) void (^selectionChanged)(NSInteger index);
@property (copy) void (^geometryChanged)(NSInteger index);
@end

@implementation VKDesignerCanvas
- (CGFloat)scaleFactor {
    if (self.documentSize.width <= 0 || self.documentSize.height <= 0) return 1;
    return MIN(1, MIN((self.bounds.size.width - 32) / self.documentSize.width, (self.bounds.size.height - 32) / self.documentSize.height));
}
- (NSRect)frameForElement:(NSDictionary *)element {
    CGFloat scale = self.scaleFactor;
    return NSMakeRect(16 + [element[@"x"] doubleValue] * scale, 16 + [element[@"y"] doubleValue] * scale,
                      [element[@"width"] doubleValue] * scale, [element[@"height"] doubleValue] * scale);
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat scale = self.scaleFactor;
    NSRect page = NSMakeRect(16, 16, self.documentSize.width * scale, self.documentSize.height * scale);
    [NSColor.whiteColor setFill]; NSRectFill(page);
    [NSColor.separatorColor setStroke]; [NSBezierPath strokeRect:page];
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:page] addClip];
    CGFloat gridSpacing = self.gridSize * scale;
    if (self.showsGrid && gridSpacing >= 8) {
        NSBezierPath *grid = [NSBezierPath bezierPath];
        for (CGFloat x = 16 + gridSpacing; x < NSMaxX(page); x += gridSpacing) {
            [grid moveToPoint:NSMakePoint(x, NSMinY(page))];
            [grid lineToPoint:NSMakePoint(x, NSMaxY(page))];
        }
        for (CGFloat y = 16 + gridSpacing; y < NSMaxY(page); y += gridSpacing) {
            [grid moveToPoint:NSMakePoint(NSMinX(page), y)];
            [grid lineToPoint:NSMakePoint(NSMaxX(page), y)];
        }
        [[NSColor colorWithCalibratedWhite:0.88 alpha:1] setStroke];
        [grid setLineWidth:0.5];
        [grid stroke];
    }
    for (NSUInteger index = 0; index < self.elements.count; index++) {
        NSDictionary *element = self.elements[index];
        NSRect frame = [self frameForElement:element];
        [colorFromHex(element[@"color"]) setFill];
        if ([element[@"type"] isEqualToString:@"circle2d"]) [[NSBezierPath bezierPathWithOvalInRect:frame] fill];
        else [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:3 yRadius:3] fill];
        [NSColor.darkGrayColor setStroke]; [NSBezierPath strokeRect:frame];
        NSString *text = element[@"text"] ?: @"";
        NSFont *font = [NSFont systemFontOfSize:MAX(10, MIN(15, 13 * scale))];
        NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor};
        [text drawInRect:NSInsetRect(frame, 5, 4) withAttributes:attributes];
        if ((NSInteger)index == self.selectedIndex) {
            [NSColor.controlAccentColor setStroke];
            NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(frame, -2, -2)];
            outline.lineWidth = 2; [outline stroke];
            [NSColor.controlAccentColor setFill];
            NSRectFill(NSMakeRect(NSMaxX(frame) - 7, NSMaxY(frame) - 7, 7, 7));
        }
    }
    [NSGraphicsContext restoreGraphicsState];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.dragIndex = -1;
    for (NSInteger index = (NSInteger)self.elements.count - 1; index >= 0; index--) {
        NSRect frame = [self frameForElement:self.elements[(NSUInteger)index]];
        if (NSPointInRect(point, frame)) {
            self.dragIndex = index; self.selectedIndex = index; self.dragStart = point; self.startFrame = frame;
            self.resizing = point.x >= NSMaxX(frame) - 12 && point.y >= NSMaxY(frame) - 12;
            break;
        }
    }
    if (self.dragIndex < 0) self.selectedIndex = -1;
    if (self.selectionChanged) self.selectionChanged(self.selectedIndex);
    self.needsDisplay = YES;
}
- (void)mouseDragged:(NSEvent *)event {
    if (self.dragIndex < 0 || (NSUInteger)self.dragIndex >= self.elements.count) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat scale = self.scaleFactor;
    CGFloat dx = (point.x - self.dragStart.x) / scale, dy = (point.y - self.dragStart.y) / scale;
    CGFloat startX = (self.startFrame.origin.x - 16) / scale, startY = (self.startFrame.origin.y - 16) / scale;
    CGFloat startWidth = self.startFrame.size.width / scale, startHeight = self.startFrame.size.height / scale;
    NSMutableDictionary *element = self.elements[(NSUInteger)self.dragIndex];
    if (self.resizing) {
        CGFloat width = startWidth + dx, height = startHeight + dy;
        if (self.snapsToGrid && self.gridSize > 0) {
            width = round(width / self.gridSize) * self.gridSize;
            height = round(height / self.gridSize) * self.gridSize;
        }
        element[@"width"] = [NSString stringWithFormat:@"%.0f", MAX(20, MIN(self.documentSize.width - startX, width))];
        element[@"height"] = [NSString stringWithFormat:@"%.0f", MAX(20, MIN(self.documentSize.height - startY, height))];
    } else {
        CGFloat x = startX + dx, y = startY + dy;
        if (self.snapsToGrid && self.gridSize > 0) {
            x = round(x / self.gridSize) * self.gridSize;
            y = round(y / self.gridSize) * self.gridSize;
        }
        element[@"x"] = [NSString stringWithFormat:@"%.0f", MAX(0, MIN(self.documentSize.width - startWidth, x))];
        element[@"y"] = [NSString stringWithFormat:@"%.0f", MAX(0, MIN(self.documentSize.height - startHeight, y))];
    }
    if (self.geometryChanged) self.geometryChanged(self.dragIndex);
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event { (void)event; self.dragIndex = -1; }
@end

typedef struct { double x, y, z; } VKVector3;
typedef struct { VKVector3 a, b, c; } VKTriangle3D;

static VKVector3 VKVectorMake(double x, double y, double z) { return (VKVector3){x, y, z}; }
static VKVector3 VKVectorAdd(VKVector3 a, VKVector3 b) { return VKVectorMake(a.x + b.x, a.y + b.y, a.z + b.z); }
static VKVector3 VKVectorSubtract(VKVector3 a, VKVector3 b) { return VKVectorMake(a.x - b.x, a.y - b.y, a.z - b.z); }
static VKVector3 VKVectorScale(VKVector3 a, double s) { return VKVectorMake(a.x * s, a.y * s, a.z * s); }
static double VKVectorDot(VKVector3 a, VKVector3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static VKVector3 VKVectorCross(VKVector3 a, VKVector3 b) { return VKVectorMake(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static double VKVectorLength(VKVector3 a) { return sqrt(VKVectorDot(a, a)); }
static VKVector3 VKVectorNormalize(VKVector3 a) { double length = VKVectorLength(a); return length > 0.000001 ? VKVectorScale(a, 1.0 / length) : VKVectorMake(0, 0, 0); }
static VKVector3 VKVectorRotateY(VKVector3 point, double angle) {
    double cosine = cos(angle), sine = sin(angle);
    return VKVectorMake(point.x * cosine + point.z * sine, point.y, -point.x * sine + point.z * cosine);
}
static void VKAppendTriangle(NSMutableArray<NSValue *> *triangles, VKVector3 a, VKVector3 b, VKVector3 c) {
    VKTriangle3D triangle = {a, b, c};
    [triangles addObject:[NSValue valueWithBytes:&triangle objCType:@encode(VKTriangle3D)]];
}
static void VKAppendQuad(NSMutableArray<NSValue *> *triangles, VKVector3 a, VKVector3 b, VKVector3 c, VKVector3 d) {
    VKAppendTriangle(triangles, a, b, c);
    VKAppendTriangle(triangles, a, c, d);
}

static NSArray<NSValue *> *VKImportMesh(NSURL *url, NSString **error) {
    NSString *extension = url.pathExtension.lowercaseString;
    if (![MDLAsset canImportFileExtension:extension]) {
        if (error) *error = [NSString stringWithFormat:@"This macOS installation cannot import .%@ models.", extension];
        return nil;
    }
    NSError *fileError = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&fileError];
    if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] > 32ull * 1024 * 1024) {
        if (error) *error = attributes ? @"Model files must be no larger than 32 MiB." : fileError.localizedDescription;
        return nil;
    }
    NSError *importError = nil;
    MDLAsset *asset = [[MDLAsset alloc] initWithURL:url vertexDescriptor:nil bufferAllocator:nil preserveTopology:NO error:&importError];
    if (!asset || importError) { if (error) *error = importError.localizedDescription ?: @"Could not read the model."; return nil; }
    NSMutableArray<NSValue *> *triangles = [NSMutableArray array];
    for (MDLMesh *mesh in [asset childObjectsOfClass:MDLMesh.class]) {
        MDLVertexAttributeData *positions = [mesh vertexAttributeDataForAttributeNamed:MDLVertexAttributePosition asFormat:MDLVertexFormatFloat3];
        if (!positions || !positions.dataStart || positions.stride < 3 * sizeof(float) || positions.bufferSize < 3 * sizeof(float)) { if (error) *error = @"Model mesh has no valid vertex positions."; return nil; }
        matrix_float4x4 transform = [MDLTransform globalTransformWithObject:mesh atTime:0];
        for (MDLSubmesh *submesh in mesh.submeshes) {
            MDLSubmesh *indexed = [[MDLSubmesh alloc] initWithMDLSubmesh:submesh indexType:MDLIndexBitDepthUInt32 geometryType:MDLGeometryTypeTriangles];
            if (!indexed || indexed.indexCount % 3 || indexed.indexCount / 3 > 100000 - triangles.count || indexed.indexCount > indexed.indexBuffer.length / sizeof(uint32_t)) {
                if (error) *error = @"Model must contain at most 100,000 valid triangles.";
                return nil;
            }
            MDLMeshBufferMap *map = [indexed.indexBuffer map];
            const uint32_t *indices = map.bytes;
            if (!indices) { if (error) *error = @"Could not read model indices."; return nil; }
            for (NSUInteger index = 0; index < indexed.indexCount; index += 3) {
                VKVector3 vertices[3];
                for (NSUInteger corner = 0; corner < 3; corner++) {
                    uint32_t vertexIndex = indices[index + corner];
                    if (vertexIndex >= mesh.vertexCount || vertexIndex > (positions.bufferSize - 3 * sizeof(float)) / positions.stride) { if (error) *error = @"Model contains an invalid vertex index."; return nil; }
                    float coordinates[3];
                    memcpy(coordinates, (const unsigned char *)positions.dataStart + vertexIndex * positions.stride, sizeof(coordinates));
                    vector_float4 vertex = simd_mul(transform, (vector_float4){coordinates[0], coordinates[1], coordinates[2], 1});
                    if (!isfinite(vertex.x) || !isfinite(vertex.y) || !isfinite(vertex.z)) { if (error) *error = @"Model contains non-finite vertex coordinates."; return nil; }
                    vertices[corner] = VKVectorMake(vertex.x, vertex.y, vertex.z);
                }
                VKAppendTriangle(triangles, vertices[0], vertices[1], vertices[2]);
            }
        }
    }
    if (!triangles.count) { if (error) *error = @"Model contains no supported triangles."; return nil; }
    return triangles;
}

static NSArray<NSValue *> *VKMeshForPrimitive(VKOpcode opcode, NSArray *values) {
    NSMutableArray<NSValue *> *triangles = [NSMutableArray array];
    if (opcode == VKUIBox3D) {
        double x = [values[3] doubleValue] / 2, y = [values[4] doubleValue] / 2, z = [values[5] doubleValue] / 2;
        VKVector3 v[] = {VKVectorMake(-x,-y,-z), VKVectorMake(x,-y,-z), VKVectorMake(x,y,-z), VKVectorMake(-x,y,-z),
                         VKVectorMake(-x,-y,z), VKVectorMake(x,-y,z), VKVectorMake(x,y,z), VKVectorMake(-x,y,z)};
        const NSUInteger faces[][4] = {{4,5,6,7},{1,0,3,2},{5,1,2,6},{0,4,7,3},{3,7,6,2},{0,1,5,4}};
        for (NSUInteger face = 0; face < 6; face++) VKAppendQuad(triangles, v[faces[face][0]], v[faces[face][1]], v[faces[face][2]], v[faces[face][3]]);
    } else if (opcode == VKUISphere3D) {
        const NSUInteger stacks = 20, slices = 32;
        double radius = [values[3] doubleValue];
        for (NSUInteger stack = 0; stack < stacks; stack++) for (NSUInteger slice = 0; slice < slices; slice++) {
            double p0 = -M_PI_2 + M_PI * stack / stacks, p1 = -M_PI_2 + M_PI * (stack + 1) / stacks;
            double t0 = 2 * M_PI * slice / slices, t1 = 2 * M_PI * (slice + 1) / slices;
            VKVector3 a = VKVectorMake(radius * cos(p0) * sin(t0), radius * sin(p0), radius * cos(p0) * cos(t0));
            VKVector3 b = VKVectorMake(radius * cos(p0) * sin(t1), radius * sin(p0), radius * cos(p0) * cos(t1));
            VKVector3 c = VKVectorMake(radius * cos(p1) * sin(t1), radius * sin(p1), radius * cos(p1) * cos(t1));
            VKVector3 d = VKVectorMake(radius * cos(p1) * sin(t0), radius * sin(p1), radius * cos(p1) * cos(t0));
            VKAppendQuad(triangles, a, b, c, d);
        }
    } else if (opcode == VKUICylinder3D || opcode == VKUICone3D) {
        const NSUInteger slices = 32;
        double topRadius = opcode == VKUICylinder3D ? [values[3] doubleValue] : [values[3] doubleValue];
        double bottomRadius = opcode == VKUICylinder3D ? topRadius : [values[4] doubleValue];
        double height = [values[opcode == VKUICylinder3D ? 4 : 5] doubleValue] / 2;
        for (NSUInteger slice = 0; slice < slices; slice++) {
            double t0 = 2 * M_PI * slice / slices, t1 = 2 * M_PI * (slice + 1) / slices;
            VKVector3 a = VKVectorMake(bottomRadius * cos(t0), -height, bottomRadius * sin(t0));
            VKVector3 b = VKVectorMake(bottomRadius * cos(t1), -height, bottomRadius * sin(t1));
            VKVector3 c = VKVectorMake(topRadius * cos(t1), height, topRadius * sin(t1));
            VKVector3 d = VKVectorMake(topRadius * cos(t0), height, topRadius * sin(t0));
            VKAppendQuad(triangles, a, b, c, d);
            VKAppendTriangle(triangles, VKVectorMake(0, -height, 0), b, a);
            VKAppendTriangle(triangles, VKVectorMake(0, height, 0), d, c);
        }
    } else if (opcode == VKUITorus3D) {
        const NSUInteger rings = 32, sides = 16;
        double major = [values[3] doubleValue], minor = [values[4] doubleValue];
        for (NSUInteger ring = 0; ring < rings; ring++) for (NSUInteger side = 0; side < sides; side++) {
            double u0 = 2 * M_PI * ring / rings, u1 = 2 * M_PI * (ring + 1) / rings;
            double v0 = 2 * M_PI * side / sides, v1 = 2 * M_PI * (side + 1) / sides;
            VKVector3 p[4];
            double us[] = {u0, u1, u1, u0}, vs[] = {v0, v0, v1, v1};
            for (NSUInteger i = 0; i < 4; i++) p[i] = VKVectorMake((major + minor * cos(vs[i])) * cos(us[i]), minor * sin(vs[i]), (major + minor * cos(vs[i])) * sin(us[i]));
            VKAppendQuad(triangles, p[0], p[1], p[2], p[3]);
        }
    } else if (opcode == VKUIPlane3D) {
        double x = [values[3] doubleValue] / 2, y = [values[4] doubleValue] / 2;
        VKAppendQuad(triangles, VKVectorMake(-x,-y,0), VKVectorMake(x,-y,0), VKVectorMake(x,y,0), VKVectorMake(-x,y,0));
    }
    return triangles;
}

@interface VK3DObject : NSObject
@property (copy) NSString *identifier;
@property (copy) NSArray<NSValue *> *triangles;
@property (strong) NSColor *color;
@property VKVector3 position;
@property VKVector3 velocity;
@property double mass;
@property double restitution;
@property double boundingRadius;
@property VKOpcode shape;
@property VKVector3 halfSize;
@property BOOL physicsEnabled;
@property NSTimeInterval spinPeriod;
@property CFTimeInterval spinStart;
@end
@implementation VK3DObject
@end

static BOOL VK3DDetectCollision(VK3DObject *first, VK3DObject *second, VKVector3 *normal, CGFloat *penetration) {
    if (first.shape == VKUIBox3D && second.shape == VKUIBox3D) {
        double now = CACurrentMediaTime();
        double firstAngle = first.spinPeriod > 0 ? (now - first.spinStart) * 2 * M_PI / first.spinPeriod : 0;
        double secondAngle = second.spinPeriod > 0 ? (now - second.spinStart) * 2 * M_PI / second.spinPeriod : 0;
        VKVector3 axes[] = {VKVectorRotateY(VKVectorMake(1, 0, 0), firstAngle), VKVectorRotateY(VKVectorMake(0, 0, 1), firstAngle), VKVectorRotateY(VKVectorMake(1, 0, 0), secondAngle), VKVectorRotateY(VKVectorMake(0, 0, 1), secondAngle), VKVectorMake(0, 1, 0)};
        VKVector3 delta = VKVectorSubtract(second.position, first.position);
        CGFloat minimum = CGFLOAT_MAX;
        for (NSUInteger index = 0; index < 5; index++) {
            VKVector3 axis = axes[index];
            double firstRadius = fabs(VKVectorDot(axis, axes[0])) * first.halfSize.x + fabs(VKVectorDot(axis, axes[1])) * first.halfSize.z + fabs(axis.y) * first.halfSize.y;
            double secondRadius = fabs(VKVectorDot(axis, axes[2])) * second.halfSize.x + fabs(VKVectorDot(axis, axes[3])) * second.halfSize.z + fabs(axis.y) * second.halfSize.y;
            double projected = VKVectorDot(delta, axis), overlap = firstRadius + secondRadius - fabs(projected);
            if (overlap <= 0) return NO;
            if (overlap < minimum) { minimum = overlap; *normal = VKVectorScale(axis, projected < 0 ? -1 : 1); }
        }
        *penetration = minimum;
        return YES;
    }
    BOOL boxFirst = first.shape == VKUIBox3D && second.shape == VKUISphere3D;
    BOOL boxSecond = first.shape == VKUISphere3D && second.shape == VKUIBox3D;
    if (boxFirst || boxSecond) {
        VK3DObject *box = boxFirst ? first : second;
        VK3DObject *sphere = boxFirst ? second : first;
        double angle = box.spinPeriod > 0 ? (CACurrentMediaTime() - box.spinStart) * 2 * M_PI / box.spinPeriod : 0;
        VKVector3 relative = VKVectorRotateY(VKVectorSubtract(sphere.position, box.position), -angle);
        VKVector3 half = box.halfSize;
        VKVector3 nearest = VKVectorMake(MAX(-half.x, MIN(half.x, relative.x)), MAX(-half.y, MIN(half.y, relative.y)), MAX(-half.z, MIN(half.z, relative.z)));
        VKVector3 delta = VKVectorSubtract(nearest, relative);
        double distance = VKVectorLength(delta), radius = sphere.boundingRadius;
        if (distance >= radius) return NO;
        VKVector3 sphereToBox;
        if (distance > 0.000001) {
            sphereToBox = VKVectorScale(delta, 1 / distance);
            *penetration = radius - distance;
        } else {
            double edgeX = half.x - fabs(relative.x), edgeY = half.y - fabs(relative.y), edgeZ = half.z - fabs(relative.z);
            if (edgeX <= edgeY && edgeX <= edgeZ) { sphereToBox = VKVectorMake(relative.x < 0 ? 1 : -1, 0, 0); *penetration = radius + edgeX; }
            else if (edgeY <= edgeZ) { sphereToBox = VKVectorMake(0, relative.y < 0 ? 1 : -1, 0); *penetration = radius + edgeY; }
            else { sphereToBox = VKVectorMake(0, 0, relative.z < 0 ? 1 : -1); *penetration = radius + edgeZ; }
        }
        sphereToBox = VKVectorRotateY(sphereToBox, angle);
        *normal = boxFirst ? VKVectorScale(sphereToBox, -1) : sphereToBox;
        return YES;
    }
    VKVector3 delta = VKVectorSubtract(second.position, first.position);
    double distance = VKVectorLength(delta);
    *penetration = first.boundingRadius + second.boundingRadius - distance;
    if (*penetration <= 0) return NO;
    *normal = distance > 0.0001 ? VKVectorScale(delta, 1 / distance) : VKVectorMake(1, 0, 0);
    return YES;
}

static NSSize VK3DRenderSize(CGFloat viewWidth, CGFloat viewHeight, CGFloat backingScale) {
    const NSUInteger maxBufferBytes = (NSUInteger)2000 * 1024 * 1024;
    const NSUInteger maxPixelCount = maxBufferBytes / (4 + sizeof(float));
    const NSUInteger maxPixelDimension = 16384;
    if (!isfinite(viewWidth) || !isfinite(viewHeight) || viewWidth <= 0 || viewHeight <= 0) return NSZeroSize;
    CGFloat renderScale = isfinite(backingScale) ? MAX(1, backingScale) : 1;
    renderScale = MIN(renderScale, sqrt((CGFloat)maxPixelCount / (viewWidth * viewHeight)));
    renderScale = MIN(renderScale, maxPixelDimension / MAX(viewWidth, viewHeight));
    NSUInteger pixelWidth = MAX(1, MIN(maxPixelDimension, (NSUInteger)ceil(viewWidth * renderScale)));
    NSUInteger pixelHeight = MAX(1, MIN(maxPixelDimension, (NSUInteger)ceil(viewHeight * renderScale)));
    while (pixelWidth * pixelHeight > maxPixelCount) {
        if (pixelWidth >= pixelHeight) pixelWidth--;
        else pixelHeight--;
    }
    return NSMakeSize(pixelWidth, pixelHeight);
}

static NSUInteger VKClipNearPlane(const VKVector3 input[3], VKVector3 output[4], double nearPlane) {
    NSUInteger count = 0;
    VKVector3 previous = input[2];
    BOOL previousInside = previous.z >= nearPlane;
    for (NSUInteger index = 0; index < 3; index++) {
        VKVector3 current = input[index];
        BOOL currentInside = current.z >= nearPlane;
        if (currentInside != previousInside) {
            double fraction = (nearPlane - previous.z) / (current.z - previous.z);
            output[count++] = VKVectorAdd(previous, VKVectorScale(VKVectorSubtract(current, previous), fraction));
        }
        if (currentInside) output[count++] = current;
        previous = current;
        previousInside = currentInside;
    }
    return count;
}

static void VKRasterizeTriangle(NSPoint points[3], double depths[3], CGFloat redValue, CGFloat greenValue, CGFloat blueValue,
                                NSUInteger pixelWidth, NSUInteger pixelHeight,
                                CGFloat viewWidth, CGFloat viewHeight,
                                unsigned char *pixels, float *depthBuffer) {
    NSPoint a = NSMakePoint(points[0].x * pixelWidth / viewWidth, points[0].y * pixelHeight / viewHeight);
    NSPoint b = NSMakePoint(points[1].x * pixelWidth / viewWidth, points[1].y * pixelHeight / viewHeight);
    NSPoint c = NSMakePoint(points[2].x * pixelWidth / viewWidth, points[2].y * pixelHeight / viewHeight);
    CGFloat area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (fabs(area) < 0.0001) return;
    NSInteger minX = MAX(0, (NSInteger)floor(MIN(a.x, MIN(b.x, c.x))));
    NSInteger maxX = MIN((NSInteger)pixelWidth - 1, (NSInteger)ceil(MAX(a.x, MAX(b.x, c.x))));
    NSInteger minY = MAX(0, (NSInteger)floor(MIN(a.y, MIN(b.y, c.y))));
    NSInteger maxY = MIN((NSInteger)pixelHeight - 1, (NSInteger)ceil(MAX(a.y, MAX(b.y, c.y))));
    unsigned char red = (unsigned char)lround(MAX(0, MIN(1, redValue)) * 255);
    unsigned char green = (unsigned char)lround(MAX(0, MIN(1, greenValue)) * 255);
    unsigned char blue = (unsigned char)lround(MAX(0, MIN(1, blueValue)) * 255);
    for (NSInteger y = minY; y <= maxY; y++) for (NSInteger x = minX; x <= maxX; x++) {
        NSPoint point = NSMakePoint(x + 0.5, y + 0.5);
        CGFloat wa = ((b.x - point.x) * (c.y - point.y) - (b.y - point.y) * (c.x - point.x)) / area;
        CGFloat wb = ((c.x - point.x) * (a.y - point.y) - (c.y - point.y) * (a.x - point.x)) / area;
        CGFloat wc = 1 - wa - wb;
        if (wa < 0 || wb < 0 || wc < 0) continue;
        double inverseDepth = wa / depths[0] + wb / depths[1] + wc / depths[2];
        NSUInteger pixel = (NSUInteger)y * pixelWidth + (NSUInteger)x;
        if (inverseDepth <= depthBuffer[pixel]) continue;
        depthBuffer[pixel] = (float)inverseDepth;
        pixels[pixel * 4] = red;
        pixels[pixel * 4 + 1] = green;
        pixels[pixel * 4 + 2] = blue;
        pixels[pixel * 4 + 3] = 255;
    }
}

static void VKMiniRasterizeTriangle(device_t *device, NSPoint points[3], double depths[3], CGFloat red, CGFloat green, CGFloat blue,
                                    CGFloat viewWidth, CGFloat viewHeight) {
    vertex_t vertices[3] = {0};
    for (NSUInteger index = 0; index < 3; index++) {
        float inverseDepth = (float)(1.0 / depths[index]);
        vertices[index].pos.x = (float)(points[index].x * device->width / viewWidth);
        vertices[index].pos.y = (float)(points[index].y * device->height / viewHeight);
        vertices[index].rhw = inverseDepth;
        vertices[index].color.r = (float)MAX(0, MIN(1, red)) * inverseDepth;
        vertices[index].color.g = (float)MAX(0, MIN(1, green)) * inverseDepth;
        vertices[index].color.b = (float)MAX(0, MIN(1, blue)) * inverseDepth;
    }
    trapezoid_t trapezoids[2];
    int count = trapezoid_init_triangle(trapezoids, &vertices[0], &vertices[1], &vertices[2]);
    for (int index = 0; index < count; index++) device_render_trap(device, &trapezoids[index]);
}

@interface VK3DView : NSView
@property (strong) NSMutableArray<VK3DObject *> *objects;
@property (strong) NSMutableArray<NSDictionary *> *lights;
@property (strong) NSMutableDictionary<NSString *, VK3DObject *> *objectsByID;
@property (strong) NSMutableDictionary<NSString *, VK3DObject *> *voxelObjects;
@property (copy) NSString *voxelColor;
@property CGFloat voxelStep;
@property (strong) NSSegmentedControl *rendererMode;
@property CGFloat cameraYaw;
@property CGFloat cameraPitch;
@property CGFloat cameraDistance;
@property VKVector3 cameraTarget;
@property NSPoint dragStart;
@property CGFloat dragYaw;
@property CGFloat dragPitch;
@property VKVector3 dragTarget;
@property BOOL dragPan;
@property BOOL dragMoved;
@property VKVector3 dragCamera;
@property (strong) NSTimer *animationTimer;
@property CFTimeInterval lastFrameTime;
@property (nonatomic) VKVector3 gravity;
@property (strong) NSArray *frameCallback;
@property (strong) NSMutableDictionary *frameVariables;
@property (strong) NSSet<NSArray<NSString *> *> *previousContacts;
- (void)setCameraPosition:(VKVector3)position;
- (void)addPointLight:(VKVector3)position intensity:(CGFloat)intensity;
- (VK3DObject *)addPrimitive:(VKOpcode)opcode values:(NSArray *)values;
- (VK3DObject *)addImportedMesh:(NSArray<NSValue *> *)triangles values:(NSArray *)values;
- (void)setSpinForID:(NSString *)identifier period:(NSTimeInterval)period;
- (void)setPhysicsForID:(NSString *)identifier mass:(CGFloat)mass restitution:(CGFloat)restitution;
- (void)setGravity:(VKVector3)gravity;
- (void)setVelocityForID:(NSString *)identifier velocity:(VKVector3)velocity;
- (void)setFrameCallback:(NSArray *)callback variables:(NSMutableDictionary *)variables;
- (void)stepFrame;
- (void)addVoxel:(VKVector3)position color:(NSString *)color;
- (void)editVoxelAtPoint:(NSPoint)point place:(BOOL)place;
- (void)moveCameraForKey:(NSString *)key;
- (void)removeObjectForID:(NSString *)identifier;
@end

@implementation VK3DView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _objects = [NSMutableArray array];
        _lights = [NSMutableArray array];
        _objectsByID = [NSMutableDictionary dictionary];
        _voxelObjects = [NSMutableDictionary dictionary];
        _previousContacts = [NSSet set];
        _cameraDistance = 12;
        _cameraTarget = VKVectorMake(0, 0, 0);
        _lastFrameTime = CACurrentMediaTime();
        _rendererMode = [NSSegmentedControl segmentedControlWithLabels:@[@"Basic", @"Regular"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeRendererMode:)];
        _rendererMode.selectedSegment = 1;
        _rendererMode.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        _rendererMode.wantsLayer = YES;
        _rendererMode.layer.backgroundColor = NSColor.whiteColor.CGColor;
        _rendererMode.layer.cornerRadius = 4;
        _rendererMode.toolTip = @"Choose the 3D renderer";
        _rendererMode.frame = NSMakeRect(MAX(0, frame.size.width - 154), 6, 148, 24);
        _rendererMode.autoresizingMask = NSViewMinXMargin;
        [self addSubview:_rendererMode];
        [self addPointLight:VKVectorMake(4, 7, 9) intensity:900];
    }
    return self;
}
- (BOOL)allowsCameraControl { return YES; }
- (void)changeRendererMode:(id)sender { (void)sender; self.needsDisplay = YES; }
- (VKVector3)cameraPosition {
    return VKVectorAdd(self.cameraTarget, VKVectorMake(self.cameraDistance * cos(self.cameraPitch) * sin(self.cameraYaw), self.cameraDistance * sin(self.cameraPitch), self.cameraDistance * cos(self.cameraPitch) * cos(self.cameraYaw)));
}
- (NSString *)voxelKey:(VKVector3)position {
    return [NSString stringWithFormat:@"%.0f,%.0f,%.0f", position.x, position.y, position.z];
}
- (void)addVoxel:(VKVector3)position color:(NSString *)color {
    NSString *key = [self voxelKey:position];
    if (self.voxelObjects[key]) return;
    VK3DObject *object = [self addPrimitive:VKUIBox3D values:@[@(position.x), @(position.y), @(position.z), @1, @1, @1, color]];
    self.voxelObjects[key] = object;
}
- (void)removeObjectForID:(NSString *)identifier {
    VK3DObject *object = self.objectsByID[identifier];
    if (!object) return;
    [self.objects removeObjectIdenticalTo:object];
    [self.objectsByID removeObjectForKey:identifier];
    self.needsDisplay = YES;
}
- (void)moveCameraForKey:(NSString *)key {
    if (self.voxelStep <= 0) return;
    VKVector3 forward = VKVectorMake(-sin(self.cameraYaw), 0, -cos(self.cameraYaw));
    VKVector3 right = VKVectorMake(cos(self.cameraYaw), 0, -sin(self.cameraYaw));
    VKVector3 movement = VKVectorMake(0, 0, 0);
    if ([key isEqualToString:@"w"]) movement = forward;
    else if ([key isEqualToString:@"s"]) movement = VKVectorScale(forward, -1);
    else if ([key isEqualToString:@"d"]) movement = right;
    else if ([key isEqualToString:@"a"]) movement = VKVectorScale(right, -1);
    else if ([key isEqualToString:@"e"] || [key isEqualToString:@"space"]) movement = VKVectorMake(0, 1, 0);
    else if ([key isEqualToString:@"q"]) movement = VKVectorMake(0, -1, 0);
    else return;
    self.cameraTarget = VKVectorAdd(self.cameraTarget, VKVectorScale(movement, self.voxelStep));
    self.needsDisplay = YES;
}
- (void)editVoxelAtPoint:(NSPoint)point place:(BOOL)place {
    if (self.voxelStep <= 0 || !self.bounds.size.width || !self.bounds.size.height) return;
    VKVector3 camera = [self cameraPosition];
    VKVector3 forward = VKVectorNormalize(VKVectorSubtract(self.cameraTarget, camera));
    VKVector3 right = VKVectorNormalize(VKVectorCross(forward, VKVectorMake(0, 1, 0)));
    VKVector3 up = VKVectorCross(right, forward);
    CGFloat focalLength = self.bounds.size.width * 0.5 / tan(M_PI / 8);
    VKVector3 ray = VKVectorNormalize(VKVectorAdd(forward, VKVectorAdd(VKVectorScale(right, (point.x - self.bounds.size.width * 0.5) / focalLength), VKVectorScale(up, (self.bounds.size.height * 0.5 - point.y) / focalLength))));
    VK3DObject *hit = nil;
    VKVector3 hitNormal = VKVectorMake(0, 0, 0);
    double closest = 12;
    for (VK3DObject *object in self.voxelObjects.allValues) {
        double origin[] = {camera.x, camera.y, camera.z}, direction[] = {ray.x, ray.y, ray.z};
        double center[] = {object.position.x, object.position.y, object.position.z};
        double nearDistance = -DBL_MAX, farDistance = DBL_MAX;
        VKVector3 nearNormal = VKVectorMake(0, 0, 0), farNormal = VKVectorMake(0, 0, 0);
        BOOL intersects = YES;
        for (NSUInteger axis = 0; axis < 3; axis++) {
            double minimum = center[axis] - 0.5, maximum = center[axis] + 0.5;
            if (fabs(direction[axis]) < 1e-12) {
                if (origin[axis] < minimum || origin[axis] > maximum) { intersects = NO; break; }
                continue;
            }
            double first = (minimum - origin[axis]) / direction[axis], second = (maximum - origin[axis]) / direction[axis];
            double firstSign = -1, secondSign = 1;
            if (first > second) { double swap = first; first = second; second = swap; firstSign = 1; secondSign = -1; }
            VKVector3 firstNormal = VKVectorMake(axis == 0 ? firstSign : 0, axis == 1 ? firstSign : 0, axis == 2 ? firstSign : 0);
            VKVector3 secondNormal = VKVectorMake(axis == 0 ? secondSign : 0, axis == 1 ? secondSign : 0, axis == 2 ? secondSign : 0);
            if (first > nearDistance) { nearDistance = first; nearNormal = firstNormal; }
            if (second < farDistance) { farDistance = second; farNormal = secondNormal; }
            if (nearDistance > farDistance) { intersects = NO; break; }
        }
        double distance = nearDistance >= 0 ? nearDistance : farDistance;
        if (intersects && distance >= 0 && distance < closest) {
            closest = distance; hit = object; hitNormal = nearDistance >= 0 ? nearNormal : farNormal;
        }
    }
    if (!hit) return;
    if (place) [self addVoxel:VKVectorAdd(hit.position, hitNormal) color:self.voxelColor];
    else {
        [self.voxelObjects removeObjectForKey:[self voxelKey:hit.position]];
        [self.objects removeObjectIdenticalTo:hit];
        self.needsDisplay = YES;
    }
}
- (void)setCameraPosition:(VKVector3)position {
    VKVector3 offset = VKVectorSubtract(position, self.cameraTarget);
    self.cameraDistance = MAX(0.5, VKVectorLength(offset));
    self.cameraYaw = atan2(offset.x, offset.z);
    self.cameraPitch = asin(MAX(-0.999, MIN(0.999, offset.y / self.cameraDistance)));
    self.needsDisplay = YES;
}
- (void)addPointLight:(VKVector3)position intensity:(CGFloat)intensity {
    [self.lights addObject:@{@"position":[NSValue valueWithBytes:&position objCType:@encode(VKVector3)], @"intensity":@(intensity)}];
    self.needsDisplay = YES;
}
- (VK3DObject *)addPrimitive:(VKOpcode)opcode values:(NSArray *)values {
    VK3DObject *object = [[VK3DObject alloc] init];
    object.triangles = VKMeshForPrimitive(opcode, values);
    object.color = colorFromHex(values.lastObject);
    object.position = VKVectorMake([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue]);
    object.mass = 1;
    object.restitution = 0.25;
    object.shape = opcode;
    if (opcode == VKUIBox3D) object.halfSize = VKVectorMake([values[3] doubleValue] / 2, [values[4] doubleValue] / 2, [values[5] doubleValue] / 2);
    for (NSValue *packed in object.triangles) {
        VKTriangle3D triangle; [packed getValue:&triangle];
        object.boundingRadius = MAX(object.boundingRadius, MAX(VKVectorLength(triangle.a), MAX(VKVectorLength(triangle.b), VKVectorLength(triangle.c))));
    }
    object.spinStart = CACurrentMediaTime();
    [self.objects addObject:object];
    self.needsDisplay = YES;
    return object;
}
- (VK3DObject *)addImportedMesh:(NSArray<NSValue *> *)triangles values:(NSArray *)values {
    VK3DObject *object = [[VK3DObject alloc] init];
    VKVector3 minimum = VKVectorMake(DBL_MAX, DBL_MAX, DBL_MAX), maximum = VKVectorMake(-DBL_MAX, -DBL_MAX, -DBL_MAX);
    for (NSValue *packed in triangles) {
        VKTriangle3D triangle; [packed getValue:&triangle];
        VKVector3 vertices[] = {triangle.a, triangle.b, triangle.c};
        for (NSUInteger index = 0; index < 3; index++) {
            minimum.x = MIN(minimum.x, vertices[index].x); minimum.y = MIN(minimum.y, vertices[index].y); minimum.z = MIN(minimum.z, vertices[index].z);
            maximum.x = MAX(maximum.x, vertices[index].x); maximum.y = MAX(maximum.y, vertices[index].y); maximum.z = MAX(maximum.z, vertices[index].z);
        }
    }
    VKVector3 center = VKVectorScale(VKVectorAdd(minimum, maximum), 0.5);
    double extent = MAX(maximum.x - minimum.x, MAX(maximum.y - minimum.y, maximum.z - minimum.z));
    double scale = [values[4] doubleValue] * (extent > 0.000001 ? 2 / extent : 1);
    NSMutableArray<NSValue *> *scaled = [NSMutableArray arrayWithCapacity:triangles.count];
    for (NSValue *packed in triangles) {
        VKTriangle3D triangle; [packed getValue:&triangle];
        triangle.a = VKVectorScale(VKVectorSubtract(triangle.a, center), scale);
        triangle.b = VKVectorScale(VKVectorSubtract(triangle.b, center), scale);
        triangle.c = VKVectorScale(VKVectorSubtract(triangle.c, center), scale);
        object.boundingRadius = MAX(object.boundingRadius, MAX(VKVectorLength(triangle.a), MAX(VKVectorLength(triangle.b), VKVectorLength(triangle.c))));
        [scaled addObject:[NSValue valueWithBytes:&triangle objCType:@encode(VKTriangle3D)]];
    }
    object.triangles = scaled;
    object.position = VKVectorMake([values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue]);
    object.color = colorFromHex(values[5]);
    object.mass = 1;
    object.restitution = 0.25;
    object.spinStart = CACurrentMediaTime();
    [self.objects addObject:object];
    self.needsDisplay = YES;
    return object;
}
- (void)setSpinForID:(NSString *)identifier period:(NSTimeInterval)period {
    VK3DObject *object = self.objectsByID[identifier];
    object.spinPeriod = period;
    object.spinStart = CACurrentMediaTime();
    [self startAnimation];
}
- (void)setPhysicsForID:(NSString *)identifier mass:(CGFloat)mass restitution:(CGFloat)restitution {
    VK3DObject *object = self.objectsByID[identifier];
    object.mass = mass;
    object.restitution = restitution;
    object.physicsEnabled = YES;
    [self startAnimation];
}
- (void)setGravity:(VKVector3)gravity {
    _gravity = gravity;
    [self startAnimation];
}
- (void)setVelocityForID:(NSString *)identifier velocity:(VKVector3)velocity {
    VK3DObject *object = self.objectsByID[identifier];
    object.velocity = velocity;
    object.physicsEnabled = YES;
    [self startAnimation];
}
- (void)setFrameCallback:(NSArray *)callback variables:(NSMutableDictionary *)variables {
    self.frameCallback = callback;
    self.frameVariables = variables;
    [self startAnimation];
}
- (void)startAnimation {
    if (self.animationTimer) return;
    __weak VK3DView *weakSelf = self;
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        VK3DView *strongSelf = weakSelf;
        if (strongSelf) [strongSelf stepFrame];
    }];
}
- (void)stepFrame {
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat elapsed = MIN(0.05, MAX(0, now - self.lastFrameTime));
    self.lastFrameTime = now;
    CGFloat maximumSpeed = 0;
    CGFloat minimumRadius = 10000;
    NSMutableArray<VK3DObject *> *physicsObjects = [NSMutableArray array];
    for (VK3DObject *object in self.objects) {
        if (!object.physicsEnabled) continue;
        [physicsObjects addObject:object];
        maximumSpeed = MAX(maximumSpeed, VKVectorLength(object.velocity));
        if (object.boundingRadius > 0) minimumRadius = MIN(minimumRadius, object.boundingRadius);
    }
    CGFloat featureSize = MAX(0.1, MIN(1, minimumRadius));
    NSUInteger substeps = MAX(1, MIN(8, (NSUInteger)ceil(maximumSpeed * elapsed / featureSize)));
    CGFloat step = elapsed / substeps;
    NSString *collisionA = @"", *collisionB = @"";
    NSMutableSet<NSArray<NSString *> *> *contacts = [NSMutableSet set];
    for (NSUInteger substep = 0; substep < substeps; substep++) {
        for (VK3DObject *object in physicsObjects) {
            if (object.mass <= 0) continue;
            object.velocity = VKVectorAdd(object.velocity, VKVectorScale(self.gravity, step));
            object.position = VKVectorAdd(object.position, VKVectorScale(object.velocity, step));
        }
        for (NSUInteger firstIndex = 0; firstIndex < physicsObjects.count; firstIndex++) for (NSUInteger secondIndex = firstIndex + 1; secondIndex < physicsObjects.count; secondIndex++) {
            VK3DObject *first = physicsObjects[firstIndex], *second = physicsObjects[secondIndex];
            VKVector3 normal;
            CGFloat penetration = 0;
            if (!VK3DDetectCollision(first, second, &normal, &penetration)) continue;
            NSArray<NSString *> *pair = @[first.identifier ?: @"", second.identifier ?: @""];
            if (![contacts containsObject:pair]) {
                if (!contacts.count) { collisionA = pair[0]; collisionB = pair[1]; }
                [contacts addObject:pair];
            }
            CGFloat inverseFirst = first.mass > 0 ? 1 / first.mass : 0;
            CGFloat inverseSecond = second.mass > 0 ? 1 / second.mass : 0;
            CGFloat inverseTotal = inverseFirst + inverseSecond;
            if (inverseTotal <= 0) continue;
            CGFloat correction = MAX(0, penetration - 0.001) * 0.8 / inverseTotal;
            first.position = VKVectorSubtract(first.position, VKVectorScale(normal, correction * inverseFirst));
            second.position = VKVectorAdd(second.position, VKVectorScale(normal, correction * inverseSecond));
            CGFloat normalSpeed = VKVectorDot(VKVectorSubtract(second.velocity, first.velocity), normal);
            if (normalSpeed < 0) {
                CGFloat impulse = -(1 + MIN(first.restitution, second.restitution)) * normalSpeed / inverseTotal;
                first.velocity = VKVectorSubtract(first.velocity, VKVectorScale(normal, impulse * inverseFirst));
                second.velocity = VKVectorAdd(second.velocity, VKVectorScale(normal, impulse * inverseSecond));
            }
        }
    }
    NSUInteger collisionCount = contacts.count;
    BOOL collisionEntered = NO, collisionExited = NO;
    for (NSArray<NSString *> *pair in contacts) if (![self.previousContacts containsObject:pair]) collisionEntered = YES;
    for (NSArray<NSString *> *pair in self.previousContacts) if (![contacts containsObject:pair]) collisionExited = YES;
    if (!collisionA.length && collisionExited) {
        NSArray<NSString *> *pair = [[self.previousContacts.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSString *> *first, NSArray<NSString *> *second) {
            NSComparisonResult order = [first[0] compare:second[0]];
            return order == NSOrderedSame ? [first[1] compare:second[1]] : order;
        }] firstObject];
        collisionA = pair[0];
        collisionB = pair[1];
    }
    self.previousContacts = [contacts copy];
    if (self.frameCallback && self.frameVariables) {
        self.frameVariables[@"delta_time"] = @(elapsed);
        self.frameVariables[@"collision"] = @(collisionCount != 0);
        self.frameVariables[@"collision_count"] = @(collisionCount);
        self.frameVariables[@"collision_a"] = collisionA;
        self.frameVariables[@"collision_b"] = collisionB;
        self.frameVariables[@"collision_entered"] = @(collisionEntered);
        self.frameVariables[@"collision_exited"] = @(collisionExited);
        NSString *error = nil;
        NSArray *actions = [VKEngine runFrameCallback:self.frameCallback variables:self.frameVariables error:&error];
        if (!actions) { NSLog(@"3D frame callback stopped: %@", error); self.frameCallback = nil; }
        else for (NSArray *action in actions) {
            VKOpcode opcode = [action[0] unsignedCharValue];
            NSArray *values = action[1];
            if (opcode == VKUIRemove3D) { [self removeObjectForID:values[0]]; continue; }
            VK3DObject *object = self.objectsByID[values[0]];
            if (!object) continue;
            VKVector3 vector = VKVectorMake([values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue]);
            if (opcode == VKUIMove3D) object.position = VKVectorAdd(object.position, vector);
            else if (opcode == VKUISetVelocity3D) { object.physicsEnabled = YES; object.velocity = vector; }
            else if (object.mass > 0) { object.physicsEnabled = YES; object.velocity = VKVectorAdd(object.velocity, VKVectorScale(vector, elapsed / object.mass)); }
        }
    }
    self.needsDisplay = YES;
}
- (void)dealloc { [self.animationTimer invalidate]; }
- (void)mouseDown:(NSEvent *)event {
    self.dragStart = [self convertPoint:event.locationInWindow fromView:nil];
    self.dragYaw = self.cameraYaw;
    self.dragPitch = self.cameraPitch;
    self.dragTarget = self.cameraTarget;
    self.dragPan = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    self.dragMoved = NO;
    self.dragCamera = [self cameraPosition];
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = point.x - self.dragStart.x, dy = point.y - self.dragStart.y;
    if (hypot(dx, dy) > 3) self.dragMoved = YES;
    if (self.dragPan && self.voxelStep <= 0) {
        VKVector3 right = VKVectorMake(cos(self.cameraYaw), 0, -sin(self.cameraYaw));
        VKVector3 up = VKVectorMake(-sin(self.cameraYaw) * sin(self.cameraPitch), cos(self.cameraPitch), -cos(self.cameraYaw) * sin(self.cameraPitch));
        CGFloat unitsPerPoint = self.cameraDistance / MAX(1, self.bounds.size.height) * 1.6;
        self.cameraTarget = VKVectorAdd(self.dragTarget, VKVectorAdd(VKVectorScale(right, -dx * unitsPerPoint), VKVectorScale(up, dy * unitsPerPoint)));
    } else {
        self.cameraYaw = self.dragYaw - dx * 0.008;
        self.cameraPitch = MAX(-1.45, MIN(1.45, self.dragPitch + dy * 0.008));
        if (self.voxelStep > 0) {
            VKVector3 offset = VKVectorMake(self.cameraDistance * cos(self.cameraPitch) * sin(self.cameraYaw), self.cameraDistance * sin(self.cameraPitch), self.cameraDistance * cos(self.cameraPitch) * cos(self.cameraYaw));
            self.cameraTarget = VKVectorSubtract(self.dragCamera, offset);
        }
    }
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    if (self.voxelStep > 0 && !self.dragMoved) [self editVoxelAtPoint:[self convertPoint:event.locationInWindow fromView:nil] place:NO];
}
- (void)rightMouseDown:(NSEvent *)event {
    if (self.voxelStep > 0) [self editVoxelAtPoint:[self convertPoint:event.locationInWindow fromView:nil] place:YES];
    else [super rightMouseDown:event];
}
- (void)scrollWheel:(NSEvent *)event {
    self.cameraDistance = MAX(0.5, MIN(5000, self.cameraDistance * exp(event.scrollingDeltaY * 0.01)));
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithSRGBRed:0.035 green:0.055 blue:0.075 alpha:1] setFill];
    NSRectFill(dirtyRect);
    if (!self.bounds.size.width || !self.bounds.size.height) return;
    CGFloat viewWidth = self.bounds.size.width, viewHeight = self.bounds.size.height;
    NSSize renderSize = VK3DRenderSize(viewWidth, viewHeight, self.window.backingScaleFactor);
    NSUInteger pixelWidth = (NSUInteger)renderSize.width, pixelHeight = (NSUInteger)renderSize.height;
    if (!pixelWidth || !pixelHeight) return;
    NSUInteger pixelCount = pixelWidth * pixelHeight;
    NSMutableData *pixelData = [NSMutableData dataWithLength:pixelCount * 4];
    NSMutableData *depthData = [NSMutableData dataWithLength:pixelCount * sizeof(float)];
    unsigned char *pixels = pixelData.mutableBytes;
    float *depthBuffer = depthData.mutableBytes;
    memset(depthBuffer, 0, pixelCount * sizeof(float));
    device_t mini = {0};
    IUINT32 **frameRows = NULL;
    float **depthRows = NULL;
    if (self.rendererMode.selectedSegment == 1) {
        frameRows = calloc(pixelHeight, sizeof(*frameRows));
        depthRows = calloc(pixelHeight, sizeof(*depthRows));
        if (frameRows && depthRows) {
            for (NSUInteger row = 0; row < pixelHeight; row++) {
                frameRows[row] = (IUINT32 *)(pixels + row * pixelWidth * 4);
                depthRows[row] = depthBuffer + row * pixelWidth;
            }
            mini.width = (int)pixelWidth;
            mini.height = (int)pixelHeight;
            mini.framebuffer = frameRows;
            mini.zbuffer = depthRows;
            mini.render_state = RENDER_STATE_COLOR;
        }
    }
    VKVector3 camera = VKVectorAdd(self.cameraTarget, VKVectorMake(self.cameraDistance * cos(self.cameraPitch) * sin(self.cameraYaw), self.cameraDistance * sin(self.cameraPitch), self.cameraDistance * cos(self.cameraPitch) * cos(self.cameraYaw)));
    VKVector3 forward = VKVectorNormalize(VKVectorSubtract(self.cameraTarget, camera));
    VKVector3 right = VKVectorNormalize(VKVectorCross(forward, VKVectorMake(0, 1, 0)));
    VKVector3 up = VKVectorCross(right, forward);
    CGFloat focalLength = self.bounds.size.width * 0.5 / tan(M_PI / 8);
    for (VK3DObject *object in self.objects) {
        double spin = object.spinPeriod > 0 ? (CACurrentMediaTime() - object.spinStart) * 2 * M_PI / object.spinPeriod : 0;
        NSColor *rgb = [object.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.whiteColor;
        for (NSValue *packed in object.triangles) {
            VKTriangle3D triangle; [packed getValue:&triangle];
            VKVector3 local[] = {triangle.a, triangle.b, triangle.c}, world[3], view[3];
            for (NSUInteger i = 0; i < 3; i++) {
                world[i] = VKVectorAdd(VKVectorRotateY(local[i], spin), object.position);
                VKVector3 relative = VKVectorSubtract(world[i], camera);
                view[i] = VKVectorMake(VKVectorDot(relative, right), VKVectorDot(relative, up), VKVectorDot(relative, forward));
            }
            VKVector3 clipped[4];
            NSUInteger clippedCount = VKClipNearPlane(view, clipped, 0.1);
            if (clippedCount < 3) continue;
            VKVector3 normal = VKVectorNormalize(VKVectorCross(VKVectorSubtract(world[1], world[0]), VKVectorSubtract(world[2], world[0])));
            VKVector3 center = VKVectorScale(VKVectorAdd(VKVectorAdd(world[0], world[1]), world[2]), 1.0 / 3.0);
            CGFloat illumination = 0.22, specular = 0;
            VKVector3 viewDirection = VKVectorNormalize(VKVectorSubtract(camera, center));
            for (NSDictionary *light in self.lights) {
                VKVector3 lightPosition; [light[@"position"] getValue:&lightPosition];
                VKVector3 toLight = VKVectorSubtract(lightPosition, center);
                double distance = VKVectorLength(toLight);
                VKVector3 direction = distance > 0.000001 ? VKVectorScale(toLight, 1.0 / distance) : VKVectorMake(0, 1, 0);
                CGFloat energy = MIN(1.5, [light[@"intensity"] doubleValue] / 1000.0) / (1 + distance * distance * 0.0025);
                illumination += MAX(0, VKVectorDot(normal, direction)) * energy;
                VKVector3 halfway = VKVectorNormalize(VKVectorAdd(direction, viewDirection));
                specular += pow(MAX(0, VKVectorDot(normal, halfway)), 24) * energy * 0.24;
            }
            illumination = MIN(1, illumination);
            specular = MIN(0.4, specular);
            for (NSUInteger corner = 1; corner + 1 < clippedCount; corner++) {
                VKVector3 projected[] = {clipped[0], clipped[corner], clipped[corner + 1]};
                NSPoint points[3];
                for (NSUInteger i = 0; i < 3; i++) points[i] = NSMakePoint(viewWidth * 0.5 + projected[i].x * focalLength / projected[i].z, viewHeight * 0.5 - projected[i].y * focalLength / projected[i].z);
                double depths[3] = {projected[0].z, projected[1].z, projected[2].z};
                CGFloat red = rgb.redComponent * illumination + specular;
                CGFloat green = rgb.greenComponent * illumination + specular;
                CGFloat blue = rgb.blueComponent * illumination + specular;
                if (mini.framebuffer) VKMiniRasterizeTriangle(&mini, points, depths, red, green, blue, viewWidth, viewHeight);
                else VKRasterizeTriangle(points, depths, red, green, blue, pixelWidth, pixelHeight, viewWidth, viewHeight, pixels, depthBuffer);
            }
        }
    }
    free(frameRows);
    free(depthRows);
    unsigned char *planes[5] = {pixels, NULL, NULL, NULL, NULL};
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:planes pixelsWide:(NSInteger)pixelWidth pixelsHigh:(NSInteger)pixelHeight bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:(NSInteger)pixelWidth * 4 bitsPerPixel:32];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *flip = [NSAffineTransform transform];
    [flip translateXBy:0 yBy:NSHeight(self.bounds)];
    [flip scaleXBy:1 yBy:-1];
    [flip concat];
    [bitmap drawInRect:self.bounds];
    [NSGraphicsContext restoreGraphicsState];
}
@end

@interface VK2DGameObject : NSObject
@property (copy) NSString *identifier;
@property NSRect frame;
@property (strong) NSColor *color;
@property CGPoint velocity;
@property CGFloat mass;
@property CGFloat restitution;
@property BOOL circle;
@end
@implementation VK2DGameObject
@end

static BOOL VK2DDetectCollision(VK2DGameObject *first, VK2DGameObject *second, CGPoint *normal, CGFloat *penetration) {
    CGFloat firstX = NSMidX(first.frame), firstY = NSMidY(first.frame);
    CGFloat secondX = NSMidX(second.frame), secondY = NSMidY(second.frame);
    if (first.circle && second.circle) {
        CGFloat dx = secondX - firstX, dy = secondY - firstY;
        CGFloat distance = hypot(dx, dy), overlap = (first.frame.size.width + second.frame.size.width) * 0.5 - distance;
        if (overlap <= 0) return NO;
        *normal = distance > 0.0001 ? CGPointMake(dx / distance, dy / distance) : CGPointMake(1, 0);
        *penetration = overlap;
        return YES;
    }
    if (!first.circle && !second.circle) {
        CGFloat dx = secondX - firstX, dy = secondY - firstY;
        CGFloat overlapX = (first.frame.size.width + second.frame.size.width) * 0.5 - fabs(dx);
        CGFloat overlapY = (first.frame.size.height + second.frame.size.height) * 0.5 - fabs(dy);
        if (overlapX <= 0 || overlapY <= 0) return NO;
        if (overlapX < overlapY) { *normal = CGPointMake(dx < 0 ? -1 : 1, 0); *penetration = overlapX; }
        else { *normal = CGPointMake(0, dy < 0 ? -1 : 1); *penetration = overlapY; }
        return YES;
    }
    BOOL reverse = !first.circle;
    VK2DGameObject *circle = reverse ? second : first;
    VK2DGameObject *box = reverse ? first : second;
    CGFloat cx = NSMidX(circle.frame), cy = NSMidY(circle.frame);
    CGFloat nearestX = MAX(NSMinX(box.frame), MIN(cx, NSMaxX(box.frame)));
    CGFloat nearestY = MAX(NSMinY(box.frame), MIN(cy, NSMaxY(box.frame)));
    CGFloat dx = nearestX - cx, dy = nearestY - cy;
    CGFloat distance = hypot(dx, dy), radius = circle.frame.size.width * 0.5;
    if (distance >= radius) return NO;
    if (distance > 0.0001) {
        *normal = CGPointMake(dx / distance, dy / distance);
        *penetration = radius - distance;
    } else {
        CGFloat left = cx - NSMinX(box.frame), right = NSMaxX(box.frame) - cx;
        CGFloat top = cy - NSMinY(box.frame), bottom = NSMaxY(box.frame) - cy;
        CGFloat edge = MIN(MIN(left, right), MIN(top, bottom));
        if (edge == left) *normal = CGPointMake(1, 0);
        else if (edge == right) *normal = CGPointMake(-1, 0);
        else if (edge == top) *normal = CGPointMake(0, 1);
        else *normal = CGPointMake(0, -1);
        *penetration = radius + edge;
    }
    if (reverse) *normal = CGPointMake(-normal->x, -normal->y);
    return YES;
}

@interface VK2DSceneView : VKCanvas
@property (strong) NSMutableArray<VK2DGameObject *> *objects;
@property (strong) NSMutableDictionary<NSString *, VK2DGameObject *> *objectsByID;
@property (strong) NSTimer *animationTimer;
@property CFTimeInterval lastFrameTime;
@property CGPoint gravity;
@property (strong) NSArray *frameCallback;
@property (strong) NSMutableDictionary *frameVariables;
@property (strong) NSSet<NSArray<NSString *> *> *previousContacts;
- (void)setPhysicsForID:(NSString *)identifier mass:(CGFloat)mass restitution:(CGFloat)restitution;
- (void)setGravityX:(CGFloat)x y:(CGFloat)y;
- (void)setFrameCallback:(NSArray *)callback variables:(NSMutableDictionary *)variables;
- (VK2DGameObject *)addObject:(NSString *)identifier frame:(NSRect)frame color:(NSColor *)color circle:(BOOL)circle;
- (void)stepFrame;
- (void)setVelocityForID:(NSString *)identifier x:(CGFloat)x y:(CGFloat)y;
- (void)moveObject:(NSString *)identifier x:(CGFloat)x y:(CGFloat)y;
@end

@implementation VK2DSceneView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _objects = [NSMutableArray array];
        _objectsByID = [NSMutableDictionary dictionaryWithCapacity:10];
        _previousContacts = [NSSet set];
        _lastFrameTime = CACurrentMediaTime();
    }
    return self;
}
- (VK2DGameObject *)addObject:(NSString *)identifier frame:(NSRect)frame color:(NSColor *)color circle:(BOOL)circle {
    VK2DGameObject *object = [[VK2DGameObject alloc] init];
    object.identifier = identifier;
    object.frame = frame;
    object.color = color;
    object.circle = circle;
    object.mass = 1;
    object.restitution = 0.25;
    [self.objects addObject:object];
    self.objectsByID[identifier] = object;
    self.needsDisplay = YES;
    return object;
}
- (void)setPhysicsForID:(NSString *)identifier mass:(CGFloat)mass restitution:(CGFloat)restitution {
    VK2DGameObject *object = self.objectsByID[identifier];
    object.mass = mass;
    object.restitution = restitution;
    [self startAnimation];
}
- (void)setGravityX:(CGFloat)x y:(CGFloat)y {
    self.gravity = CGPointMake(x, y);
    [self startAnimation];
}
- (void)setFrameCallback:(NSArray *)callback variables:(NSMutableDictionary *)variables {
    self.frameCallback = callback;
    self.frameVariables = variables;
    [self startAnimation];
}
- (void)startAnimation {
    if (self.animationTimer) return;
    __weak VK2DSceneView *weakSelf = self;
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        VK2DSceneView *strongSelf = weakSelf;
        if (strongSelf) [strongSelf stepFrame];
    }];
}
- (void)setVelocityForID:(NSString *)identifier x:(CGFloat)x y:(CGFloat)y {
    VK2DGameObject *object = self.objectsByID[identifier];
    object.velocity = CGPointMake(x, y);
    [self startAnimation];
}
- (void)stepFrame {
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat elapsed = MIN(0.05, MAX(0, now - self.lastFrameTime));
    self.lastFrameTime = now;
    CGFloat maximumSpeed = 0;
    for (VK2DGameObject *object in self.objects) maximumSpeed = MAX(maximumSpeed, hypot(object.velocity.x, object.velocity.y));
    CGFloat minimumSize = MAX(8, MIN(self.bounds.size.width, self.bounds.size.height) / 40);
    NSUInteger substeps = MAX(1, MIN(8, (NSUInteger)ceil(maximumSpeed * elapsed / minimumSize)));
    CGFloat step = elapsed / substeps;
    NSString *collisionA = @"", *collisionB = @"";
    NSMutableSet<NSArray<NSString *> *> *contacts = [NSMutableSet set];
    for (NSUInteger substep = 0; substep < substeps; substep++) {
        for (VK2DGameObject *object in self.objects) {
            if (object.mass <= 0) continue;
            object.velocity = CGPointMake(object.velocity.x + self.gravity.x * step, object.velocity.y + self.gravity.y * step);
            NSRect frame = object.frame;
            frame.origin.x += object.velocity.x * step;
            frame.origin.y += object.velocity.y * step;
            if (frame.size.width >= self.bounds.size.width) { frame.origin.x = 0; object.velocity = CGPointMake(0, object.velocity.y); }
            else if (frame.origin.x < 0) { frame.origin.x = 0; object.velocity = CGPointMake(fabs(object.velocity.x) * object.restitution, object.velocity.y); }
            else if (NSMaxX(frame) > self.bounds.size.width) { frame.origin.x = self.bounds.size.width - frame.size.width; object.velocity = CGPointMake(-fabs(object.velocity.x) * object.restitution, object.velocity.y); }
            if (frame.size.height >= self.bounds.size.height) { frame.origin.y = 0; object.velocity = CGPointMake(object.velocity.x, 0); }
            else if (frame.origin.y < 0) { frame.origin.y = 0; object.velocity = CGPointMake(object.velocity.x, fabs(object.velocity.y) * object.restitution); }
            else if (NSMaxY(frame) > self.bounds.size.height) { frame.origin.y = self.bounds.size.height - frame.size.height; object.velocity = CGPointMake(object.velocity.x, -fabs(object.velocity.y) * object.restitution); }
            object.frame = frame;
        }
        for (NSUInteger firstIndex = 0; firstIndex < self.objects.count; firstIndex++) for (NSUInteger secondIndex = firstIndex + 1; secondIndex < self.objects.count; secondIndex++) {
            VK2DGameObject *first = self.objects[firstIndex], *second = self.objects[secondIndex];
            CGPoint normal; CGFloat penetration = 0;
            if (!VK2DDetectCollision(first, second, &normal, &penetration)) continue;
            NSArray<NSString *> *pair = @[first.identifier, second.identifier];
            if (![contacts containsObject:pair]) {
                if (!contacts.count) { collisionA = pair[0]; collisionB = pair[1]; }
                [contacts addObject:pair];
            }
            CGFloat inverseFirst = first.mass > 0 ? 1 / first.mass : 0;
            CGFloat inverseSecond = second.mass > 0 ? 1 / second.mass : 0;
            CGFloat inverseTotal = inverseFirst + inverseSecond;
            if (inverseTotal <= 0) continue;
            CGFloat correction = MAX(0, penetration - 0.01) * 0.8 / inverseTotal;
            first.frame = NSOffsetRect(first.frame, -normal.x * correction * inverseFirst, -normal.y * correction * inverseFirst);
            second.frame = NSOffsetRect(second.frame, normal.x * correction * inverseSecond, normal.y * correction * inverseSecond);
            CGFloat relativeX = second.velocity.x - first.velocity.x;
            CGFloat relativeY = second.velocity.y - first.velocity.y;
            CGFloat normalSpeed = relativeX * normal.x + relativeY * normal.y;
            if (normalSpeed < 0) {
                CGFloat restitution = MIN(first.restitution, second.restitution);
                CGFloat impulse = -(1 + restitution) * normalSpeed / inverseTotal;
                first.velocity = CGPointMake(first.velocity.x - impulse * normal.x * inverseFirst, first.velocity.y - impulse * normal.y * inverseFirst);
                second.velocity = CGPointMake(second.velocity.x + impulse * normal.x * inverseSecond, second.velocity.y + impulse * normal.y * inverseSecond);
            }
        }
    }
    NSUInteger collisionCount = contacts.count;
    BOOL collisionEntered = NO, collisionExited = NO;
    for (NSArray<NSString *> *pair in contacts) if (![self.previousContacts containsObject:pair]) collisionEntered = YES;
    for (NSArray<NSString *> *pair in self.previousContacts) if (![contacts containsObject:pair]) collisionExited = YES;
    if (!collisionA.length && collisionExited) {
        NSArray<NSString *> *pair = [[self.previousContacts.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSString *> *first, NSArray<NSString *> *second) {
            NSComparisonResult order = [first[0] compare:second[0]];
            return order == NSOrderedSame ? [first[1] compare:second[1]] : order;
        }] firstObject];
        collisionA = pair[0];
        collisionB = pair[1];
    }
    self.previousContacts = [contacts copy];
    if (self.frameCallback && self.frameVariables) {
        self.frameVariables[@"delta_time"] = @(elapsed);
        self.frameVariables[@"collision"] = @(collisionCount != 0);
        self.frameVariables[@"collision_count"] = @(collisionCount);
        self.frameVariables[@"collision_a"] = collisionA;
        self.frameVariables[@"collision_b"] = collisionB;
        self.frameVariables[@"collision_entered"] = @(collisionEntered);
        self.frameVariables[@"collision_exited"] = @(collisionExited);
        NSString *error = nil;
        NSArray *actions = [VKEngine runFrameCallback:self.frameCallback variables:self.frameVariables error:&error];
        if (!actions) {
            NSLog(@"Frame callback stopped: %@", error);
            self.frameCallback = nil;
        } else for (NSArray *action in actions) {
            VKOpcode opcode = [action[0] unsignedCharValue];
            NSArray *values = action[1];
            NSString *identifier = values[0];
            VK2DGameObject *object = self.objectsByID[identifier];
            if (!object) continue;
            if (opcode == VKUIMove2D) [self moveObject:identifier x:[values[1] doubleValue] y:[values[2] doubleValue]];
            else if (opcode == VKUISetVelocity2D) object.velocity = CGPointMake([values[1] doubleValue], [values[2] doubleValue]);
            else if (object.mass > 0) object.velocity = CGPointMake(object.velocity.x + [values[1] doubleValue] * elapsed / object.mass,
                                                                      object.velocity.y + [values[2] doubleValue] * elapsed / object.mass);
        }
    }
    self.needsDisplay = YES;
}
- (void)moveObject:(NSString *)identifier x:(CGFloat)x y:(CGFloat)y {
    VK2DGameObject *object = self.objectsByID[identifier];
    if (!object) return;
    NSRect frame = object.frame;
    frame.origin.x = MAX(0, MIN(self.bounds.size.width - frame.size.width, frame.origin.x + x));
    frame.origin.y = MAX(0, MIN(self.bounds.size.height - frame.size.height, frame.origin.y + y));
    object.frame = frame;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithSRGBRed:0.035 green:0.075 blue:0.105 alpha:1] setFill];
    NSRectFill(dirtyRect);
    [[NSColor colorWithSRGBRed:0.14 green:0.25 blue:0.28 alpha:0.55] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    for (CGFloat x = 24; x < self.bounds.size.width; x += 24) { [grid moveToPoint:NSMakePoint(x, 0)]; [grid lineToPoint:NSMakePoint(x, self.bounds.size.height)]; }
    for (CGFloat y = 24; y < self.bounds.size.height; y += 24) { [grid moveToPoint:NSMakePoint(0, y)]; [grid lineToPoint:NSMakePoint(self.bounds.size.width, y)]; }
    [grid setLineWidth:0.5]; [grid stroke];
    for (VK2DGameObject *object in self.objects) {
        NSBezierPath *shape = object.circle ? [NSBezierPath bezierPathWithOvalInRect:object.frame] : [NSBezierPath bezierPathWithRoundedRect:object.frame xRadius:4 yRadius:4];
        [object.color setFill]; [shape fill];
        [[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0.65] setStroke];
        [shape setLineWidth:1]; [shape stroke];
    }
}
- (void)dealloc { [self.animationTimer invalidate]; }
@end

@interface VKActionButton : NSButton
@property (copy) NSString *message;
@end
@implementation VKActionButton
@end

@interface VKBoundInputField : NSTextField
@property (copy) NSString *bindingVariable;
@property (strong) NSMutableDictionary<NSString *, NSString *> *boundValues;
@property (strong) NSArray<NSTextField *> *boundLabels;
@property (strong) NSArray<VKBoundInputField *> *boundInputs;
@end
@implementation VKBoundInputField
@end

static NSString *programKeyForEvent(NSEvent *event) {
    switch (event.keyCode) {
        case kVK_F1: return @"f1"; case kVK_F2: return @"f2"; case kVK_F3: return @"f3";
        case kVK_F4: return @"f4"; case kVK_F5: return @"f5"; case kVK_F6: return @"f6";
        case kVK_F7: return @"f7"; case kVK_F8: return @"f8"; case kVK_F9: return @"f9";
        case kVK_F10: return @"f10"; case kVK_F11: return @"f11"; case kVK_F12: return @"f12";
        case kVK_Home: return @"home"; case kVK_End: return @"end";
        case kVK_PageUp: return @"pageup"; case kVK_PageDown: return @"pagedown";
        case kVK_Help: return @"insert"; case kVK_ForwardDelete: return @"delete";
        case kVK_Delete: return @"backspace"; case kVK_Return: case kVK_ANSI_KeypadEnter: return @"enter";
        case kVK_Escape: return @"escape"; case kVK_Tab: return @"tab"; case kVK_Space: return @"space";
        case kVK_LeftArrow: return @"left"; case kVK_RightArrow: return @"right";
        case kVK_UpArrow: return @"up"; case kVK_DownArrow: return @"down";
        default: return event.charactersIgnoringModifiers.lowercaseString ?: @"";
    }
}

static BOOL testInstrumentRendering(NSString *instrument) {
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioUnitSampler *sampler = [[AVAudioUnitSampler alloc] init];
    [engine attachNode:sampler];
    [engine connect:sampler to:engine.mainMixerNode format:nil];
    NSError *error = nil;
    NSURL *bank = [NSURL fileURLWithPath:@"/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"];
    UInt8 program = [instrument isEqualToString:@"guitar"] ? 24 : 0;
    if (![sampler loadSoundBankInstrumentAtURL:bank program:program bankMSB:kAUSampler_DefaultMelodicBankMSB bankLSB:kAUSampler_DefaultBankLSB error:&error]) return NO;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:4096 error:&error]) return NO;
    if (![engine startAndReturnError:&error]) return NO;
    [sampler startNote:60 withVelocity:100 onChannel:0];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
    BOOL nonzero = NO;
    for (NSUInteger block = 0; block < 4 && !nonzero; block++) {
        if ([engine renderOffline:4096 toBuffer:buffer error:&error] != AVAudioEngineManualRenderingStatusSuccess) break;
        for (AVAudioFrameCount frame = 0; frame < buffer.frameLength; frame++) if (fabsf(buffer.floatChannelData[0][frame]) > 0.00001f) { nonzero = YES; break; }
    }
    [sampler stopNote:60 onChannel:0];
    [engine stop];
    return nonzero;
}

@interface VKProgramWindow : NSWindow
@property (copy) void (^focusedKeyHandler)(NSString *key);
@property (copy) void (^focusedRepeatKeyHandler)(NSString *key);
@property (copy) NSArray<NSString *> *registeredKeys;
@end
@implementation VKProgramWindow
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown && self.isKeyWindow) {
        NSString *key = programKeyForEvent(event);
        if (key.length && self.focusedRepeatKeyHandler) self.focusedRepeatKeyHandler(key);
        if (key.length && !event.isARepeat && self.focusedKeyHandler) self.focusedKeyHandler(key);
    }
    [super sendEvent:event];
}
@end

@interface VKTestProgramWindow : VKProgramWindow
@property BOOL testFocus;
@end
@implementation VKTestProgramWindow
- (BOOL)isKeyWindow { return self.testFocus; }
@end

@interface VKApp : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (strong) NSWindow *window;
@property (strong) NSTextView *editor;
@property (strong) NSTextView *output;
@property (strong) NSURL *fileURL;
@property (strong) NSURL *pendingURL;
@property (copy) NSString *savedSource;
@property BOOL discardApproved;
@property (strong) NSWindow *builder;
@property (strong) NSWindow *builderCodeWindow;
@property (strong) NSTextView *builderCodeView;
@property (strong) NSTextField *builderCodeStatus;
@property (strong) NSTextField *builderTitle;
@property (strong) NSTextField *builderWidth;
@property (strong) NSTextField *builderHeight;
@property (strong) NSArray<NSTextField *> *builderCamera3D;
@property (strong) NSArray<NSTextField *> *builderGravity3D;
@property (strong) NSPopUpButton *builderTemplates;
@property (strong) NSTableView *table;
@property (strong) VKDesignerCanvas *designerCanvas;
@property (strong) NSColorWell *designerColor;
@property (strong) NSButton *designerGridSnap;
@property (strong) NSStepper *designerGridSize;
@property (strong) NSTextField *designerGridSizeLabel;
@property (strong) NSMutableArray<NSString *> *builderSoundPaths;
@property (strong) NSMutableArray<NSMutableDictionary *> *elements;
@property (strong) NSMutableArray<NSWindow *> *previewWindows;
@property (strong) AVAudioEngine *audioEngine;
@property (strong) NSMutableDictionary<NSString *, AVAudioUnitSampler *> *instrumentSamplers;
@property (strong) NSMutableArray<NSSound *> *activeSounds;
@property BOOL launcherMode;
@property (copy) NSString *incomingSource;
@property (strong) NSTextField *launcherFileLabel;
@property (strong) NSOutlineView *explorer;
@property (strong) NSTextField *projectLabel;
@property (strong) NSTextField *sourceLabel;
@property (strong) NSURL *projectURL;
@property (strong) NSMutableDictionary<NSString *, NSArray<NSURL *> *> *folderCache;
@property (strong) NSMutableDictionary<NSString *, NSURL *> *projectItems;
@property BOOL restoringSelection;
@property (strong) NSMutableSet<NSTask *> *runningTasks;
@property CGFloat codeFontSize;
@property (strong) NSView *manualView;
@property (strong) NSTableView *manualTable;
@property (strong) NSSearchField *manualSearch;
@property (strong) NSPopUpButton *manualCategory;
@property (strong) NSSegmentedControl *manualDimension;
@property (strong) NSSegmentedControl *manualSort;
@property (strong) NSTextField *manualPageLabel;
@property (strong) NSMutableArray<NSString *> *manualBaseMatches;
@property (strong) NSMutableDictionary<NSString *, NSNumber *> *manualCategoryBaseCounts;
@property NSUInteger manualCount;
@property NSUInteger manualPage;
@end

static NSButton *button(NSString *title, NSRect frame, id target, SEL action) {
    NSButton *control = [NSButton buttonWithTitle:title target:target action:action];
    control.frame = frame;
    control.bezelStyle = NSBezelStyleRounded;
    control.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    control.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    control.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: control.font, NSForegroundColorAttributeName: NSColor.blackColor}];
    return control;
}

static NSTextField *field(NSString *value, NSRect frame) {
    NSTextField *control = [[NSTextField alloc] initWithFrame:frame];
    control.stringValue = value;
    return control;
}

static NSString *quote(NSString *value) {
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:@[value] options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *json = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    return [json substringWithRange:NSMakeRange(1, json.length - 2)];
}

static CGFloat contrast(NSColor *first, NSColor *second, NSAppearance *appearance) {
    __block CGFloat result = 0;
    [appearance performAsCurrentDrawingAppearance:^{
        NSColor *colors[] = {[first colorUsingColorSpace:NSColorSpace.sRGBColorSpace], [second colorUsingColorSpace:NSColorSpace.sRGBColorSpace]};
        CGFloat luminance[2] = {0, 0};
        for (NSUInteger index = 0; index < 2; index++) {
            if (!colors[index]) return;
            CGFloat components[] = {colors[index].redComponent, colors[index].greenComponent, colors[index].blueComponent};
            CGFloat weights[] = {0.2126, 0.7152, 0.0722};
            for (NSUInteger component = 0; component < 3; component++) {
                CGFloat channel = components[component];
                luminance[index] += weights[component] * (channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4));
            }
        }
        result = (MAX(luminance[0], luminance[1]) + 0.05) / (MIN(luminance[0], luminance[1]) + 0.05);
    }];
    return result;
}

@implementation VKApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.previewWindows = [NSMutableArray array];
    self.elements = [NSMutableArray array];
    self.builderSoundPaths = [NSMutableArray array];
    self.folderCache = [NSMutableDictionary dictionary];
    self.projectItems = [NSMutableDictionary dictionary];
    self.runningTasks = [NSMutableSet set];
    NSApp.applicationIconImage = vektkoveDockIcon();
    CGFloat savedSize = [[NSUserDefaults standardUserDefaults] doubleForKey:@"VektkoveCodeFontSize"];
    self.codeFontSize = savedSize >= 12 && savedSize <= 30 ? savedSize : 16;
    [self createMenu];
    if (self.launcherMode) { [self createLauncherWindow]; return; }
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 720) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Vektkove 1.4.1";
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(800, 570);
    [self.window center];
    NSView *content = [[VKBackgroundView alloc] initWithFrame:self.window.contentView.bounds];
    self.window.contentView = content;
    VKBrandMarkView *brandMark = [[VKBrandMarkView alloc] initWithFrame:NSMakeRect(24, 664, 36, 36)];
    brandMark.autoresizingMask = NSViewMinYMargin;
    brandMark.accessibilityLabel = @"Vektkove cube logo";
    [content addSubview:brandMark];
    NSTextField *heading = [NSTextField labelWithString:@"VEKTKOVE  /  CODE STUDIO"];
    heading.frame = NSMakeRect(72, 672, 500, 28);
    heading.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    heading.autoresizingMask = NSViewMinYMargin;
    [content addSubview:heading];
    NSArray *titles = @[@"New", @"Open Folder", @"Save", @"Compile", @"Test Code", @"UI Maker", @"3D Editor"];
    NSArray *actions = @[@"newFile:", @"openFolder:", @"saveFile:", @"compileFile:", @"runCode:", @"showBuilder:", @"show3DEditor:"];
    NSArray *positions = @[@20, @109, @213, @297, @386, @480, @574];
    NSArray *widths = @[@85, @100, @80, @85, @90, @90, @90];
    for (NSUInteger index = 0; index < titles.count; index++) {
        NSButton *control = button(titles[index], NSMakeRect([positions[index] doubleValue], 634, [widths[index] doubleValue], 30), self, NSSelectorFromString(actions[index]));
        if (index == 6) control.toolTip = @"Open the 3D scene editor";
        control.autoresizingMask = NSViewMinYMargin;
        [content addSubview:control];
    }
    NSButton *smaller = button(@"A-", NSMakeRect(690, 634, 45, 30), self, @selector(smallerText:));
    NSButton *larger = button(@"A+", NSMakeRect(738, 634, 45, 30), self, @selector(largerText:));
    smaller.toolTip = @"Decrease code text size"; larger.toolTip = @"Increase code text size";
    smaller.autoresizingMask = larger.autoresizingMask = NSViewMinYMargin;
    [content addSubview:smaller]; [content addSubview:larger];
    self.projectLabel = [NSTextField labelWithString:@"EXPLORER"];
    self.projectLabel.frame = NSMakeRect(24, 606, 205, 16);
    self.projectLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
    self.projectLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.projectLabel.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.projectLabel];
    NSArray *explorerTitles = @[@"+ File", @"+ Folder", @"Refresh"];
    NSArray *explorerActions = @[@"newProjectFile:", @"newProjectFolder:", @"refreshExplorer:"];
    NSArray *explorerSymbols = @[@"doc.badge.plus", @"folder.badge.plus", @"arrow.clockwise"];
    NSArray *explorerHints = @[@"New file", @"New folder", @"Refresh explorer"];
    for (NSUInteger index = 0; index < explorerTitles.count; index++) {
        NSButton *control = button(explorerTitles[index], NSMakeRect(20 + index * 70, 567, 70, 26), self, NSSelectorFromString(explorerActions[index]));
        NSImage *image = [NSImage imageWithSystemSymbolName:explorerSymbols[index] accessibilityDescription:explorerHints[index]];
        if (image) { control.image = image; control.imagePosition = NSImageOnly; control.contentTintColor = NSColor.blackColor; }
        control.toolTip = explorerHints[index];
        control.autoresizingMask = NSViewMinYMargin;
        [content addSubview:control];
    }
    NSScrollView *explorerScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 70, 210, 487)];
    explorerScroll.borderType = NSBezelBorder;
    explorerScroll.hasVerticalScroller = YES;
    explorerScroll.autoresizingMask = NSViewHeightSizable;
    self.explorer = [[NSOutlineView alloc] initWithFrame:explorerScroll.bounds];
    NSTableColumn *fileColumn = [[NSTableColumn alloc] initWithIdentifier:@"file"];
    fileColumn.width = 205;
    [self.explorer addTableColumn:fileColumn];
    self.explorer.outlineTableColumn = fileColumn;
    self.explorer.headerView = nil;
    self.explorer.rowHeight = 28;
    self.explorer.backgroundColor = NSColor.controlBackgroundColor;
    self.explorer.dataSource = self;
    self.explorer.delegate = self;
    explorerScroll.documentView = self.explorer;
    [content addSubview:explorerScroll];
    self.sourceLabel = [NSTextField labelWithString:@"SOURCE  /  UNTITLED"];
    self.sourceLabel.frame = NSMakeRect(245, 606, 280, 16);
    self.sourceLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
    self.sourceLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.sourceLabel.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
    [content addSubview:self.sourceLabel];
    NSScrollView *editorScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(245, 70, 831, 525)];
    editorScroll.borderType = NSBezelBorder;
    editorScroll.hasVerticalScroller = YES;
    editorScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.editor = [[NSTextView alloc] initWithFrame:editorScroll.bounds];
    [self configureTextView:self.editor fontSize:self.codeFontSize inset:NSMakeSize(16, 14)];
    self.editor.string = @"# Your first Vektkove program\ntext greeting \"Hello from Vektkove\"\nout $greeting\nset total 2\nadd total 3\nout $total\nhalt\n";
    self.savedSource = self.editor.string;
    self.editor.delegate = self;
    self.editor.automaticQuoteSubstitutionEnabled = NO;
    self.editor.automaticDashSubstitutionEnabled = NO;
    editorScroll.documentView = self.editor;
    [content addSubview:editorScroll];
    NSSegmentedControl *tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Editor", @"Manual"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];
    tabs.frame = NSMakeRect(540, 598, 215, 30);
    tabs.selectedSegment = 0;
    tabs.autoresizingMask = NSViewMinYMargin;
    [content addSubview:tabs];
    [self createManualInView:content frame:editorScroll.frame];
    NSScrollView *outputScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(245, 24, 831, 30)];
    outputScroll.borderType = NSBezelBorder;
    outputScroll.hasVerticalScroller = YES;
    outputScroll.autoresizingMask = NSViewWidthSizable;
    self.output = [[NSTextView alloc] initWithFrame:outputScroll.bounds];
    self.output.editable = NO;
    [self configureTextView:self.output fontSize:13 inset:NSMakeSize(5, 4)];
    self.output.string = @"Ready. Open a project folder or write a .vk program.";
    outputScroll.documentView = self.output;
    [content addSubview:outputScroll];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (self.pendingURL) { NSURL *url = self.pendingURL; self.pendingURL = nil; [self openSourceURL:url]; }
}

- (void)createMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [main addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:self.launcherMode ? @"VektkoveLauncher" : @"Vektkove"];
    NSMenuItem *aboutItem = [appMenu addItemWithTitle:@"About Vektkove" action:@selector(showAbout:) keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:self.launcherMode ? @"Quit VektkoveLauncher" : @"Quit Vektkove" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [main addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [main addItem:viewItem];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *larger = [view addItemWithTitle:@"Increase Text Size" action:@selector(largerText:) keyEquivalent:@"+"]; larger.target = self;
    NSMenuItem *smaller = [view addItemWithTitle:@"Decrease Text Size" action:@selector(smallerText:) keyEquivalent:@"-"]; smaller.target = self;
    NSMenuItem *reset = [view addItemWithTitle:@"Reset Text Size" action:@selector(resetText:) keyEquivalent:@"0"]; reset.target = self;
    viewItem.submenu = view;
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [main insertItem:fileItem atIndex:1];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    if (self.launcherMode) {
        NSMenuItem *openItem = [file addItemWithTitle:@"Open .vk..." action:@selector(openLauncherFile:) keyEquivalent:@"o"]; openItem.target = self;
        NSMenuItem *testItem = [file addItemWithTitle:@"Test Code" action:@selector(runCode:) keyEquivalent:@"r"]; testItem.target = self;
        fileItem.submenu = file;
        NSApp.mainMenu = main;
        return;
    }
    NSMenuItem *newItem = [file addItemWithTitle:@"New" action:@selector(newFile:) keyEquivalent:@"n"]; newItem.target = self;
    NSMenuItem *openItem = [file addItemWithTitle:@"Open..." action:@selector(openFile:) keyEquivalent:@"o"]; openItem.target = self;
    NSMenuItem *folderItem = [file addItemWithTitle:@"Open Folder..." action:@selector(openFolder:) keyEquivalent:@"O"]; folderItem.target = self;
    NSMenuItem *saveItem = [file addItemWithTitle:@"Save" action:@selector(saveFile:) keyEquivalent:@"s"]; saveItem.target = self;
    NSMenuItem *saveAsItem = [file addItemWithTitle:@"Save As..." action:@selector(saveAs:) keyEquivalent:@"S"]; saveAsItem.target = self;
    fileItem.submenu = file;
    NSApp.mainMenu = main;
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSString *licensePath = [NSBundle.mainBundle pathForResource:@"Mini3D-LICENSE" ofType:@"txt"];
    NSString *miniLicense = licensePath ? [NSString stringWithContentsOfFile:licensePath encoding:NSUTF8StringEncoding error:nil] : @"";
    NSString *jsonPath = [NSBundle.mainBundle pathForResource:@"cJSON-LICENSE" ofType:@"txt"];
    NSString *jsonLicense = jsonPath ? [NSString stringWithContentsOfFile:jsonPath encoding:NSUTF8StringEncoding error:nil] : @"";
    NSString *creditText = [NSString stringWithFormat:@"Regular 3D rasterizer: Mini3D by Linwei (skywind3000).\n\n%@\n\nJSON parsing: cJSON by Dave Gamble and contributors.\n\n%@\n\n%@", miniLicense, jsonLicense, VKLicenseText];
    NSAttributedString *credits = [[NSAttributedString alloc] initWithString:creditText attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10]}];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: @"Vektkove",
        NSAboutPanelOptionApplicationVersion: @"1.4.1",
        NSAboutPanelOptionCredits: credits
    }];
}

- (void)configureTextView:(NSTextView *)view fontSize:(CGFloat)fontSize inset:(NSSize)inset {
    view.font = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
    view.textColor = NSColor.textColor;
    view.backgroundColor = NSColor.textBackgroundColor;
    view.insertionPointColor = NSColor.textColor;
    view.textContainerInset = inset;
    view.usesFindPanel = YES;
}
- (void)setReadableFontSize:(CGFloat)size {
    self.codeFontSize = MIN(30, MAX(12, size));
    if (!self.launcherMode) self.editor.font = [NSFont monospacedSystemFontOfSize:self.codeFontSize weight:NSFontWeightRegular];
    else self.output.font = [NSFont monospacedSystemFontOfSize:self.codeFontSize weight:NSFontWeightRegular];
}
- (void)adjustTextSize:(CGFloat)delta {
    [self setReadableFontSize:self.codeFontSize + delta];
    [[NSUserDefaults standardUserDefaults] setDouble:self.codeFontSize forKey:@"VektkoveCodeFontSize"];
}
- (void)largerText:(id)sender { (void)sender; [self adjustTextSize:1]; }
- (void)smallerText:(id)sender { (void)sender; [self adjustTextSize:-1]; }
- (void)resetText:(id)sender { (void)sender; [self setReadableFontSize:16]; [[NSUserDefaults standardUserDefaults] setDouble:self.codeFontSize forKey:@"VektkoveCodeFontSize"]; }

- (void)createManualInView:(NSView *)content frame:(NSRect)frame {
    self.manualView = [[NSView alloc] initWithFrame:frame];
    self.manualView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.manualView.hidden = YES;
    self.manualSearch = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, frame.size.height - 34, 180, 26)];
    self.manualSearch.placeholderString = @"Search keywords";
    self.manualSearch.delegate = self;
    self.manualSearch.autoresizingMask = NSViewMinYMargin;
    [self.manualView addSubview:self.manualSearch];
    self.manualCategory = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(188, frame.size.height - 34, 125, 26) pullsDown:NO];
    [self.manualCategory setTarget:self];
    [self.manualCategory setAction:@selector(manualCategoryChanged:)];
    self.manualCategory.autoresizingMask = NSViewMinYMargin;
    self.manualCategory.toolTip = @"Filter the command list by category";
    [self.manualView addSubview:self.manualCategory];
    [self reloadManualCategories];
    self.manualSort = [NSSegmentedControl segmentedControlWithLabels:@[@"A-Z", @"Groups"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(manualSortChanged:)];
    self.manualSort.frame = NSMakeRect(321, frame.size.height - 34, 127, 26);
    self.manualSort.selectedSegment = 0;
    self.manualSort.autoresizingMask = NSViewMinYMargin;
    self.manualSort.toolTip = @"Sort command names A-Z or group them by category";
    [self.manualView addSubview:self.manualSort];
    self.manualDimension = [NSSegmentedControl segmentedControlWithLabels:@[@"All", @"2D", @"3D"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(manualDimensionChanged:)];
    self.manualDimension.frame = NSMakeRect(0, frame.size.height - 68, 210, 26);
    self.manualDimension.selectedSegment = 0;
    self.manualDimension.autoresizingMask = NSViewMinYMargin;
    self.manualDimension.toolTip = @"Show all, 2D, or 3D commands";
    [self.manualView addSubview:self.manualDimension];
    NSButton *previous = button(@"<", NSMakeRect(frame.size.width - 215, frame.size.height - 68, 42, 26), self, @selector(previousManualPage:));
    NSButton *next = button(@">", NSMakeRect(frame.size.width - 47, frame.size.height - 68, 42, 26), self, @selector(nextManualPage:));
    previous.toolTip = @"Previous commands"; next.toolTip = @"Next commands";
    previous.autoresizingMask = next.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.manualView addSubview:previous]; [self.manualView addSubview:next];
    self.manualPageLabel = [NSTextField labelWithString:@""];
    self.manualPageLabel.frame = NSMakeRect(frame.size.width - 169, frame.size.height - 64, 118, 20);
    self.manualPageLabel.alignment = NSTextAlignmentCenter;
    self.manualPageLabel.font = [NSFont systemFontOfSize:11];
    self.manualPageLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.manualView addSubview:self.manualPageLabel];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - 76)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    self.manualTable = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.manualTable.rowHeight = 28;
    for (NSArray *specification in @[@[@"keyword", @"Command", @160], @[@"help", @"Operands and behavior", @500], @[@"category", @"Category", @100]]) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:specification[0]];
        column.title = specification[1]; column.width = [specification[2] doubleValue]; column.editable = NO;
        [(NSTextFieldCell *)column.dataCell setFont:[NSFont systemFontOfSize:13]];
        [self.manualTable addTableColumn:column];
    }
    self.manualTable.dataSource = self;
    self.manualTable.delegate = self;
    scroll.documentView = self.manualTable;
    [self.manualView addSubview:scroll];
    [content addSubview:self.manualView];
}

- (void)changeTab:(NSSegmentedControl *)tabs {
    BOOL showManual = tabs.selectedSegment == 1;
    self.editor.enclosingScrollView.hidden = showManual;
    self.manualView.hidden = !showManual;
    if (showManual) { self.sourceLabel.stringValue = @"COMMAND MANUAL"; [self filterManual]; }
    else [self updateSourceLabel];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.manualSearch) [self filterManual];
    if (notification.object == self.builderTitle || notification.object == self.builderWidth || notification.object == self.builderHeight) [self refreshDesignerCanvas];
    if ([self.builderCamera3D containsObject:notification.object] || [self.builderGravity3D containsObject:notification.object]) [self refreshBuilderCodePreview];
    if ([notification.object isKindOfClass:VKBoundInputField.class]) {
        VKBoundInputField *input = notification.object;
        if (input.bindingVariable.length) {
            input.boundValues[input.bindingVariable] = input.stringValue;
            for (NSTextField *label in input.boundLabels) label.stringValue = input.stringValue;
            for (VKBoundInputField *peer in input.boundInputs) if (peer != input) peer.stringValue = input.stringValue;
        }
    }
}
- (void)manualCategoryChanged:(id)sender {
    (void)sender;
    NSInteger selected = self.manualCategory.selectedItem.tag;
    [self reloadManualCategories];
    [self.manualCategory selectItemAtIndex:MAX(0, MIN(selected, (NSInteger)self.manualCategory.numberOfItems - 1))];
    [self filterManual];
}
- (void)manualSortChanged:(id)sender { (void)sender; [self filterManual]; }
- (void)manualDimensionChanged:(id)sender {
    (void)sender;
    [self reloadManualCategories];
    [self.manualCategory selectItemAtIndex:0];
    [self filterManual];
}
- (void)reloadManualCategories {
    NSArray *names = @[@"Code", @"Logic", @"Math", @"Text", @"UI"];
    NSUInteger counts[5] = {0, 0, 0, 0, 0};
    NSUInteger total = 0;
    NSInteger selectedDimension = self.manualDimension.selectedSegment == 1 ? 2 : self.manualDimension.selectedSegment == 2 ? 3 : 0;
    for (NSUInteger index = 0; index < VKEngine.baseKeywordCount; index++) {
        NSString *keyword = [VKEngine keywordAtIndex:index];
        NSInteger dimension = [VKEngine dimensionForKeyword:keyword];
        if (selectedDimension && dimension != selectedDimension && dimension != -1) continue;
        NSString *category = [VKEngine categoryForKeyword:keyword];
        NSUInteger categoryIndex = [names indexOfObject:category];
        if (categoryIndex < 5) { counts[categoryIndex]++; total++; }
    }
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    [self.manualCategory removeAllItems];
    [self.manualCategory addItemWithTitle:[NSString stringWithFormat:@"All (%@)", [formatter stringFromNumber:@(total)]]];
    self.manualCategory.lastItem.tag = 0;
    for (NSUInteger index = 0; index < names.count; index++) {
        [self.manualCategory addItemWithTitle:[NSString stringWithFormat:@"%@ (%@)", names[index], [formatter stringFromNumber:@(counts[index])]]];
        self.manualCategory.lastItem.tag = (NSInteger)index + 1;
    }
}

- (void)filterManual {
    NSString *query = [self.manualSearch.stringValue.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSInteger categoryTag = self.manualCategory.selectedItem.tag;
    NSArray *categoryNames = @[@"Code", @"Logic", @"Math", @"Text", @"UI"];
    NSString *selectedCategory = categoryTag > 0 && categoryTag <= (NSInteger)categoryNames.count ? categoryNames[(NSUInteger)categoryTag - 1] : nil;
    self.manualBaseMatches = [NSMutableArray array];
    self.manualCategoryBaseCounts = [NSMutableDictionary dictionary];
    self.manualCount = 0; self.manualPage = 0;
    NSInteger selectedDimension = self.manualDimension.selectedSegment == 1 ? 2 : self.manualDimension.selectedSegment == 2 ? 3 : 0;
    for (NSUInteger index = 0; index < VKEngine.baseKeywordCount; index++) {
        NSString *keyword = [VKEngine keywordAtIndex:index];
        NSInteger dimension = [VKEngine dimensionForKeyword:keyword];
        if ((!selectedDimension || dimension == selectedDimension || dimension == -1) &&
            (!query.length || [keyword hasPrefix:query]) && (!selectedCategory || [[VKEngine categoryForKeyword:keyword] isEqualToString:selectedCategory])) [self.manualBaseMatches addObject:keyword];
    }
    if (self.manualSort.selectedSegment == 1) {
        [self.manualBaseMatches sortUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
            NSUInteger firstCategory = [categoryNames indexOfObject:[VKEngine categoryForKeyword:first]];
            NSUInteger secondCategory = [categoryNames indexOfObject:[VKEngine categoryForKeyword:second]];
            if (firstCategory != secondCategory) return firstCategory < secondCategory ? NSOrderedAscending : NSOrderedDescending;
            return [first compare:second options:NSLiteralSearch];
        }];
        for (NSString *category in categoryNames) self.manualCategoryBaseCounts[category] = @0;
        for (NSString *keyword in self.manualBaseMatches) {
            NSString *category = [VKEngine categoryForKeyword:keyword];
            self.manualCategoryBaseCounts[category] = @([self.manualCategoryBaseCounts[category] unsignedIntegerValue] + 1);
        }
    }
    self.manualCount = self.manualBaseMatches.count;
    [self reloadManualPage];
}
- (NSString *)manualKeywordAtPosition:(NSUInteger)position {
    return position < self.manualBaseMatches.count ? self.manualBaseMatches[position] : nil;
}

- (void)reloadManualPage {
    NSUInteger first = self.manualPage * 500;
    NSUInteger last = MIN(first + 500, self.manualCount);
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    self.manualPageLabel.stringValue = self.manualCount ? [NSString stringWithFormat:@"%@-%@ / %@", [formatter stringFromNumber:@(first + 1)], [formatter stringFromNumber:@(last)], [formatter stringFromNumber:@(self.manualCount)]] : @"No matches";
    [self.manualTable reloadData];
    if (self.manualTable.numberOfRows > 0) [self.manualTable scrollRowToVisible:0];
}
- (void)previousManualPage:(id)sender { (void)sender; if (self.manualPage) { self.manualPage--; [self reloadManualPage]; } }
- (void)nextManualPage:(id)sender { (void)sender; if ((self.manualPage + 1) * 500 < self.manualCount) { self.manualPage++; [self reloadManualPage]; } }

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    self.window.documentEdited = ![self.editor.string isEqualToString:self.savedSource];
    [self updateSourceLabel];
}
- (void)updateSourceLabel {
    if (self.manualView && !self.manualView.hidden) { self.sourceLabel.stringValue = @"COMMAND MANUAL"; return; }
    NSString *name = self.fileURL.lastPathComponent ?: @"UNTITLED";
    self.sourceLabel.stringValue = [NSString stringWithFormat:@"SOURCE  /  %@%@", name, self.window.documentEdited ? @" *" : @""];
}
- (BOOL)confirmDiscard {
    if (self.launcherMode) return YES;
    if ([self.editor.string isEqualToString:self.savedSource]) return YES;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Save changes to your Vektkove program?";
    alert.informativeText = @"Your changes will be lost if you don't save them.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Discard"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) return [self saveSource:NO];
    return response == NSAlertSecondButtonReturn;
}
- (void)newFile:(id)sender {
    (void)sender;
    if (![self confirmDiscard]) return;
    self.fileURL = nil; self.editor.string = @""; self.savedSource = @""; self.window.documentEdited = NO; self.output.string = @"New program.";
    [self updateSourceLabel];
}
- (BOOL)openSourceURL:(NSURL *)url {
    if (![self confirmDiscard]) return NO;
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
    if (!source) { self.output.string = error.localizedDescription; return NO; }
    self.fileURL = url;
    self.editor.string = source;
    self.savedSource = source;
    self.window.documentEdited = NO;
    [self updateSourceLabel];
    self.output.string = [NSString stringWithFormat:@"Opened %@.", url.lastPathComponent];
    [self.window makeKeyAndOrderFront:nil];
    return YES;
}
- (void)openFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"vk"]];
    if ([panel runModal] != NSModalResponseOK) return;
    [self openSourceURL:panel.URL];
}
- (BOOL)saveSource:(BOOL)forcePanel {
    NSURL *destination = self.fileURL;
    if (!destination || forcePanel) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"vk"]];
        panel.nameFieldStringValue = destination.lastPathComponent ?: @"program.vk";
        if (self.projectURL) panel.directoryURL = self.projectURL;
        if ([panel runModal] != NSModalResponseOK) return NO;
        destination = panel.URL;
    }
    NSError *error = nil;
    if (![self.editor.string writeToURL:destination atomically:YES encoding:NSUTF8StringEncoding error:&error]) { self.output.string = error.localizedDescription; return NO; }
    self.fileURL = destination;
    self.savedSource = self.editor.string;
    self.window.documentEdited = NO;
    [self updateSourceLabel];
    self.output.string = [NSString stringWithFormat:@"Saved %@.", destination.lastPathComponent];
    if (self.projectURL) [self refreshExplorer:nil];
    return YES;
}
- (void)saveFile:(id)sender { (void)sender; [self saveSource:NO]; }
- (void)saveAs:(id)sender { (void)sender; [self saveSource:YES]; }

- (void)setProjectFolder:(NSURL *)url {
    char canonical[PATH_MAX];
    self.projectURL = realpath(url.fileSystemRepresentation, canonical) ? [NSURL fileURLWithFileSystemRepresentation:canonical isDirectory:YES relativeToURL:nil] : url;
    [self.projectItems removeAllObjects];
    self.projectLabel.stringValue = [NSString stringWithFormat:@"EXPLORER  /  %@", self.projectURL.lastPathComponent];
    [self refreshExplorer:nil];
}
- (void)openFolder:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    if ([panel runModal] == NSModalResponseOK) [self setProjectFolder:panel.URL];
}
- (void)refreshExplorer:(id)sender {
    (void)sender;
    [self.folderCache removeAllObjects];
    [self.explorer reloadData];
}
- (BOOL)isFolder:(NSURL *)url {
    NSNumber *directory = nil, *symbolic = nil;
    [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
    return directory.boolValue && !symbolic.boolValue;
}
- (NSArray<NSURL *> *)childrenOfFolder:(NSURL *)folder {
    if (!folder) return @[];
    NSArray *cached = self.folderCache[folder.path];
    if (cached) return cached;
    NSError *error = nil;
    NSArray<NSURL *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:folder includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&error];
    if (!children) { self.output.string = [NSString stringWithFormat:@"Cannot read %@: %@", folder.lastPathComponent, error.localizedDescription]; return @[]; }
    NSMutableArray *stableItems = [NSMutableArray arrayWithCapacity:children.count];
    for (NSURL *child in children) {
        NSURL *stable = self.projectItems[child.path];
        if (!stable) { stable = child; self.projectItems[child.path] = stable; }
        [stableItems addObject:stable];
    }
    NSArray *sorted = [stableItems sortedArrayUsingComparator:^NSComparisonResult(NSURL *first, NSURL *second) {
        BOOL firstFolder = [self isFolder:first], secondFolder = [self isFolder:second];
        if (firstFolder != secondFolder) return firstFolder ? NSOrderedAscending : NSOrderedDescending;
        return [first.lastPathComponent localizedStandardCompare:second.lastPathComponent];
    }];
    self.folderCache[folder.path] = sorted;
    return sorted;
}
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item { (void)outlineView; return (NSInteger)[self childrenOfFolder:item ?: self.projectURL].count; }
- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item { (void)outlineView; return [self childrenOfFolder:item ?: self.projectURL][(NSUInteger)index]; }
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item { (void)outlineView; return [self isFolder:item]; }
- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)column item:(id)item {
    (void)column;
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"fileCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 190, 28)];
        cell.identifier = @"fileCell";
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 5, 18, 18)];
        NSTextField *label = [NSTextField labelWithString:@""];
        label.frame = NSMakeRect(26, 4, 163, 20);
        label.font = [NSFont systemFontOfSize:14];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        label.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:icon]; [cell addSubview:label];
        cell.imageView = icon; cell.textField = label;
    }
    NSURL *url = item;
    cell.textField.stringValue = url.lastPathComponent;
    cell.imageView.image = [[NSWorkspace sharedWorkspace] iconForFile:url.path];
    return cell;
}
- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.restoringSelection) return;
    NSInteger row = self.explorer.selectedRow;
    if (row < 0) return;
    NSURL *url = [self.explorer itemAtRow:row];
    if (![self isFolder:url] && ![url isEqual:self.fileURL] && ![self openSourceURL:url]) {
        self.restoringSelection = YES;
        NSURL *previousItem = self.fileURL ? self.projectItems[self.fileURL.URLByResolvingSymlinksInPath.path] : nil;
        NSInteger previous = previousItem ? [self.explorer rowForItem:previousItem] : -1;
        if (previous >= 0) [self.explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)previous] byExtendingSelection:NO];
        else [self.explorer deselectAll:nil];
        self.restoringSelection = NO;
    }
}
- (NSURL *)selectedProjectFolder {
    NSInteger row = self.explorer.selectedRow;
    NSURL *selected = row >= 0 ? [self.explorer itemAtRow:row] : nil;
    return selected ? ([self isFolder:selected] ? selected : selected.URLByDeletingLastPathComponent) : self.projectURL;
}
- (void)createProjectItemIsFolder:(BOOL)isFolder {
    NSURL *parent = [self selectedProjectFolder];
    if (!parent) { self.output.string = @"Open a project folder first."; return; }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = isFolder ? @"New Folder" : @"New Vektkove File";
    [alert addButtonWithTitle:@"Create"]; [alert addButtonWithTitle:@"Cancel"];
    NSTextField *nameField = field(isFolder ? @"folder" : @"program.vk", NSMakeRect(0, 0, 260, 24));
    alert.accessoryView = nameField;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *error = nil;
    NSURL *url = [self createProjectItem:nameField.stringValue parent:parent folder:isFolder error:&error];
    if (!url) { self.output.string = error; return; }
    [self refreshExplorer:nil];
    if (![parent isEqual:self.projectURL]) [self.explorer expandItem:parent];
    self.output.string = [NSString stringWithFormat:@"Created %@.", url.lastPathComponent];
    if (!isFolder) [self openSourceURL:url];
}
- (NSURL *)createProjectItem:(NSString *)input parent:(NSURL *)parent folder:(BOOL)isFolder error:(NSString **)error {
    NSString *name = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"]) { if (error) *error = @"Invalid file or folder name."; return nil; }
    if (!isFolder && !name.pathExtension.length) name = [name stringByAppendingPathExtension:@"vk"];
    NSURL *url = [parent URLByAppendingPathComponent:name isDirectory:isFolder];
    NSError *fileError = nil;
    BOOL created = isFolder ? [[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:NO attributes:nil error:&fileError] : [[NSData data] writeToURL:url options:NSDataWritingWithoutOverwriting error:&fileError];
    if (!created) { if (error) *error = [NSString stringWithFormat:@"Could not create %@: %@", name, fileError.localizedDescription]; return nil; }
    return url;
}
- (void)newProjectFile:(id)sender { (void)sender; [self createProjectItemIsFolder:NO]; }
- (void)newProjectFolder:(id)sender { (void)sender; [self createProjectItemIsFolder:YES]; }
- (void)compileFile:(id)sender {
    (void)sender;
    NSString *error = nil;
    NSData *code = [VKEngine compile:self.editor.string error:&error];
    if (!code) { self.output.string = error; return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"vkb"]];
    panel.nameFieldStringValue = @"program.vkb";
    if ([panel runModal] != NSModalResponseOK) return;
    NSError *fileError = nil;
    if (![code writeToURL:panel.URL options:NSDataWritingAtomic error:&fileError]) self.output.string = fileError.localizedDescription;
    else self.output.string = [NSString stringWithFormat:@"Compiled %lu bytes to %@.", (unsigned long)code.length, panel.URL.lastPathComponent];
}
- (void)runCode:(id)sender {
    (void)sender;
    if (!self.launcherMode) {
        NSError *launchError = nil;
        if (![self startLauncherWithSource:self.editor.string arguments:@[] output:nil error:&launchError]) { self.output.string = [NSString stringWithFormat:@"Could not open VektkoveLauncher: %@", launchError.localizedDescription]; return; }
        self.output.string = @"Testing current editor contents in VektkoveLauncher.";
        return;
    }
    if (!self.incomingSource && !self.fileURL) { self.output.string = @"Open a .vk file before testing."; return; }
    NSString *error = nil;
    NSArray<NSString *> *diagnostics = [VKEngine diagnose:self.editor.string];
    NSUInteger errorCount = 0;
    for (NSString *line in diagnostics) if ([line hasPrefix:@"Error"]) errorCount++;
    NSString *report = diagnostics.count ? [[diagnostics componentsJoinedByString:@"\n"] stringByAppendingFormat:@"\n%lu error%@, %lu warning%@.\n", (unsigned long)errorCount, errorCount == 1 ? @"" : @"s", (unsigned long)(diagnostics.count - errorCount), diagnostics.count - errorCount == 1 ? @"" : @"s"] : @"";
    NSData *code = [VKEngine compile:self.editor.string error:&error];
    if (!code) { self.output.string = errorCount ? [report stringByAppendingString:@"Not run: fix the errors above."] : [@"Compile error: " stringByAppendingString:error]; return; }
    if (errorCount) { self.output.string = [report stringByAppendingString:@"Not run: fix the errors above."]; return; }
    NSMutableArray *ui = [NSMutableArray array];
    NSString *output = [VKEngine run:code ui:ui error:&error];
    if (!output) { self.output.string = [report stringByAppendingFormat:@"Runtime error: %@", error]; return; }
    self.output.string = [report stringByAppendingString:output.length ? output : @"Finished with no output."];
    if (ui.count) [self showUI:ui];
}

- (NSTask *)startLauncherWithSource:(NSString *)source arguments:(NSArray<NSString *> *)arguments output:(NSPipe *)output error:(NSError **)error {
    NSURL *folder = [NSBundle.mainBundle.bundleURL URLByDeletingLastPathComponent];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [folder URLByAppendingPathComponent:@"VektkoveLauncher.app/Contents/MacOS/VektkoveLauncher"];
    task.arguments = [@[@"--stdin"] arrayByAddingObjectsFromArray:arguments];
    NSURL *workingDirectory = self.fileURL.URLByDeletingLastPathComponent ?: self.projectURL;
    if (workingDirectory) task.currentDirectoryURL = workingDirectory;
    NSPipe *input = [NSPipe pipe];
    task.standardInput = input;
    if (output) { task.standardOutput = output; task.standardError = output; }
    __weak VKApp *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.runningTasks removeObject:finished]; });
    };
    [self.runningTasks addObject:task];
    if (![task launchAndReturnError:error]) { [self.runningTasks removeObject:task]; return nil; }
    NSData *encoded = [source dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try { [input.fileHandleForWriting writeData:encoded]; [input.fileHandleForWriting closeFile]; }
        @catch (NSException *exception) { NSLog(@"Launcher input error: %@", exception.reason); }
    });
    return task;
}

- (void)createLauncherWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 480) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"VektkoveLauncher";
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(520, 360);
    [self.window center];
    NSView *content = [[VKBackgroundView alloc] initWithFrame:self.window.contentView.bounds];
    self.window.contentView = content;
    NSTextField *heading = [NSTextField labelWithString:@"VEKTKOVE LAUNCHER"];
    heading.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    heading.frame = NSMakeRect(20, 435, 360, 28);
    heading.autoresizingMask = NSViewMinYMargin;
    [content addSubview:heading];
    NSButton *smaller = button(@"A-", NSMakeRect(610, 430, 45, 30), self, @selector(smallerText:));
    NSButton *larger = button(@"A+", NSMakeRect(658, 430, 45, 30), self, @selector(largerText:));
    smaller.toolTip = @"Decrease output text size"; larger.toolTip = @"Increase output text size";
    smaller.autoresizingMask = larger.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [content addSubview:smaller]; [content addSubview:larger];
    NSButton *open = button(@"Open .vk", NSMakeRect(20, 390, 105, 30), self, @selector(openLauncherFile:));
    NSButton *test = button(@"Test Code", NSMakeRect(130, 390, 110, 30), self, @selector(runCode:));
    open.autoresizingMask = test.autoresizingMask = NSViewMinYMargin;
    [content addSubview:open]; [content addSubview:test];
    self.launcherFileLabel = [NSTextField labelWithString:self.incomingSource ? @"Current editor contents" : @"No program selected"];
    self.launcherFileLabel.frame = NSMakeRect(250, 395, 440, 20);
    self.launcherFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.launcherFileLabel.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
    [content addSubview:self.launcherFileLabel];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 680, 350)];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.output = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.output.editable = NO;
    [self configureTextView:self.output fontSize:self.codeFontSize inset:NSMakeSize(16, 14)];
    self.output.string = @"Open a .vk file to test it.";
    scroll.documentView = self.output;
    [content addSubview:scroll];
    self.editor = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.editor.string = self.incomingSource ?: @"";
    self.savedSource = self.editor.string;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (self.incomingSource) [self runCode:nil];
}

- (void)openLauncherFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"vk"]];
    if ([panel runModal] != NSModalResponseOK) return;
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfURL:panel.URL encoding:NSUTF8StringEncoding error:&error];
    if (!source) { self.output.string = error.localizedDescription; return; }
    self.fileURL = panel.URL;
    self.launcherFileLabel.stringValue = panel.URL.lastPathComponent;
    self.editor.string = source;
    self.savedSource = source;
    self.output.string = @"Program loaded. Select Test Code.";
}

- (void)showUI:(NSArray *)ui {
    NSArray *windowValues = ui[0][1];
    VKProgramWindow *window = [[VKProgramWindow alloc] initWithContentRect:NSMakeRect(0, 0, [windowValues[1] doubleValue], [windowValues[2] doubleValue]) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.title = [windowValues[0] description];
    window.releasedWhenClosed = NO;
    VKCanvas *canvas = [[VKCanvas alloc] initWithFrame:window.contentView.bounds];
    window.contentView = canvas;
    NSMutableDictionary<NSString *, NSArray *> *keyActions = [NSMutableDictionary dictionary];
    NSMutableArray<NSArray *> *startupActions = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSView *> *viewsByID = [NSMutableDictionary dictionary];
    NSMutableArray<NSArray *> *bindings = [NSMutableArray array];
    NSView *lastControl = nil;
    VK3DObject *lastSceneObject = nil;
    VK3DView *sceneView = nil;
    VK2DSceneView *scene2DView = nil;
    for (NSUInteger index = 1; index < ui.count; index++) {
        VKOpcode opcode = [ui[index][0] unsignedCharValue];
        NSArray *values = ui[index][1];
        if (opcode == VKUIShortcut || opcode == VKUIKeynote || opcode == VKUIKeyMove2D || opcode == VKUIKeyMove3D) {
            NSString *key = values[(opcode == VKUIKeyMove2D || opcode == VKUIKeyMove3D) ? 1 : 0];
            keyActions[[key lowercaseString]] = @[@(opcode), values];
            continue;
        }
        if (opcode == VKUIKeyboard) {
            NSString *keys = @"awsedftgyhujkolp;";
            for (NSUInteger keyIndex = 0; keyIndex < keys.length; keyIndex++) {
                NSString *key = [keys substringWithRange:NSMakeRange(keyIndex, 1)];
                keyActions[key] = @[@(VKUIKeynote), @[key, values[0], @([values[1] unsignedIntegerValue] + keyIndex), @0.4]];
            }
            continue;
        }
        if (opcode == VKUIAutoTurn) {
            if (lastControl) {
                lastControl.wantsLayer = YES;
                CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
                rotation.fromValue = @0;
                rotation.toValue = @(2 * M_PI);
                rotation.duration = [values[0] doubleValue];
                rotation.repeatCount = HUGE_VALF;
                [lastControl.layer addAnimation:rotation forKey:@"vektkove.auto_turn"];
            }
            continue;
        }
        if (opcode == VKUIID) {
            if (lastControl) viewsByID[values[0]] = lastControl;
            if (lastSceneObject) {
                lastSceneObject.identifier = values[0];
                sceneView.objectsByID[values[0]] = lastSceneObject;
            }
            continue;
        }
        if (opcode == VKUIBind) { [bindings addObject:values]; continue; }
        if (opcode == VKUINote || opcode == VKUISound) { [startupActions addObject:@[@(opcode), values]]; continue; }
        if (opcode == VKUIScene3D) {
            sceneView = [[VK3DView alloc] initWithFrame:NSMakeRect([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue])];
            sceneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [canvas addSubview:sceneView];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUICamera3D) {
            [sceneView setCameraPosition:VKVectorMake([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue])];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUILight3D) {
            [sceneView addPointLight:VKVectorMake([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue]) intensity:[values[3] doubleValue]];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode >= VKUIBox3D && opcode <= VKUIPlane3D) {
            lastSceneObject = [sceneView addPrimitive:opcode values:values];
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIMesh3D) {
            NSURL *base = self.fileURL.URLByDeletingLastPathComponent ?: [NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath isDirectory:YES];
            NSURL *modelURL = [NSURL fileURLWithPath:values[0] relativeToURL:base];
            NSString *modelError = nil;
            NSArray *triangles = VKImportMesh(modelURL, &modelError);
            if (!triangles) {
                self.output.string = [NSString stringWithFormat:@"Could not import %@: %@", modelURL.lastPathComponent, modelError ?: @"Unknown error."];
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Could not import 3D model";
                alert.informativeText = self.output.string;
                [alert beginSheetModalForWindow:window completionHandler:nil];
                lastSceneObject = nil;
            } else lastSceneObject = [sceneView addImportedMesh:triangles values:values];
            lastControl = nil;
            continue;
        }
        if (opcode == VKUISpin3D) {
            [sceneView setSpinForID:values[0] period:[values[1] doubleValue]];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIPhysics3D) {
            [sceneView setPhysicsForID:values[0] mass:[values[1] doubleValue] restitution:[values[2] doubleValue]];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIGravity3D) {
            [sceneView setGravity:VKVectorMake([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue])];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIVelocity3D) {
            [sceneView setVelocityForID:values[0] velocity:VKVectorMake([values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue])];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIVoxel3D) {
            [sceneView addVoxel:VKVectorMake([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue]) color:values[3]];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIVoxelControls3D) {
            sceneView.voxelStep = [values[0] doubleValue];
            sceneView.voxelColor = values[1];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIRemove3D) {
            [sceneView removeObjectForID:values[0]];
            lastSceneObject = nil;
            lastControl = nil;
            continue;
        }
        if (opcode == VKUIScene2D) {
            scene2DView = [[VK2DSceneView alloc] initWithFrame:NSMakeRect([values[0] doubleValue], [values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue])];
            scene2DView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [canvas addSubview:scene2DView];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUIFrameData) {
            if ([values[0] unsignedCharValue] == VKUIScene3D) [sceneView setFrameCallback:values[1] variables:values[2]];
            else [scene2DView setFrameCallback:values[1] variables:values[2]];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUIRect2D || opcode == VKUICircle2D) {
            BOOL circle = opcode == VKUICircle2D;
            CGFloat width = [values[3] doubleValue];
            CGFloat height = circle ? width : [values[4] doubleValue];
            [scene2DView addObject:values[0]
                             frame:NSMakeRect([values[1] doubleValue], [values[2] doubleValue], width, height)
                             color:colorFromHex(values.lastObject)
                            circle:circle];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUIGravity2D) {
            [scene2DView setGravityX:[values[0] doubleValue] y:[values[1] doubleValue]];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUIPhysics2D) {
            [scene2DView setPhysicsForID:values[0] mass:[values[1] doubleValue] restitution:[values[2] doubleValue]];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        if (opcode == VKUIVelocity2D) {
            [scene2DView setVelocityForID:values[0] x:[values[1] doubleValue] y:[values[2] doubleValue]];
            lastControl = nil;
            lastSceneObject = nil;
            continue;
        }
        NSRect frame = NSMakeRect([values[1] doubleValue], [values[2] doubleValue], [values[3] doubleValue], [values[4] doubleValue]);
        NSColor *background = colorFromHex(values.lastObject);
        if (opcode == VKUILabel) {
            NSTextField *label = [NSTextField labelWithString:[values[0] description]];
            label.frame = frame;
            label.wantsLayer = YES;
            label.layer.backgroundColor = background.CGColor;
            label.textColor = textColorForBackground(background);
            [canvas addSubview:label];
            lastControl = label;
            lastSceneObject = nil;
        } else if (opcode == VKUIInput) {
            VKBoundInputField *input = [[VKBoundInputField alloc] initWithFrame:frame];
            input.editable = YES;
            input.selectable = YES;
            input.bordered = YES;
            input.drawsBackground = YES;
            input.placeholderString = [values[0] description];
            input.backgroundColor = background;
            input.textColor = textColorForBackground(background);
            input.delegate = self;
            [canvas addSubview:input];
            lastControl = input;
            lastSceneObject = nil;
        } else if (opcode == VKUIButton) {
            VKActionButton *control = [[VKActionButton alloc] initWithFrame:frame];
            control.title = [values[0] description];
            control.bezelStyle = NSBezelStyleRounded;
            control.bezelColor = background;
            control.contentTintColor = textColorForBackground(background);
            control.message = [values[5] description];
            control.target = self;
            control.action = @selector(showMessage:);
            [canvas addSubview:control];
            lastControl = control;
            lastSceneObject = nil;
        }
    }
    NSMutableDictionary<NSString *, NSString *> *boundValues = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSTextField *> *> *labelsByVariable = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<VKBoundInputField *> *> *inputsByVariable = [NSMutableDictionary dictionary];
    for (NSArray *binding in bindings) boundValues[binding[1]] = binding[2];
    for (NSArray *binding in bindings) {
        NSView *view = viewsByID[binding[0]];
        NSString *variable = binding[1];
        if ([view isKindOfClass:VKBoundInputField.class]) continue;
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField *label = (NSTextField *)view;
            label.stringValue = boundValues[variable] ?: @"";
            if (!labelsByVariable[variable]) labelsByVariable[variable] = [NSMutableArray array];
            [labelsByVariable[variable] addObject:label];
        }
    }
    for (NSArray *binding in bindings) {
        NSView *view = viewsByID[binding[0]];
        if (![view isKindOfClass:VKBoundInputField.class]) continue;
        VKBoundInputField *input = (VKBoundInputField *)view;
        input.bindingVariable = binding[1];
        input.boundValues = boundValues;
        input.boundLabels = labelsByVariable[binding[1]] ?: @[];
        if (!inputsByVariable[binding[1]]) inputsByVariable[binding[1]] = [NSMutableArray array];
        [inputsByVariable[binding[1]] addObject:input];
        input.stringValue = boundValues[binding[1]] ?: @"";
    }
    for (NSArray *binding in bindings) {
        NSView *view = viewsByID[binding[0]];
        if ([view isKindOfClass:VKBoundInputField.class]) ((VKBoundInputField *)view).boundInputs = inputsByVariable[binding[1]];
    }
    __weak VKApp *weakSelf = self;
    __weak VKProgramWindow *weakWindow = window;
    __weak VK3DView *weakSceneView = sceneView;
    window.focusedRepeatKeyHandler = ^(NSString *key) { [weakSceneView moveCameraForKey:key]; };
    window.registeredKeys = keyActions.allKeys;
    window.focusedKeyHandler = ^(NSString *key) {
        NSArray *action = keyActions[key];
        if (!action) return;
        VKApp *strongSelf = weakSelf;
        NSArray *values = action[1];
        if ([action[0] unsignedCharValue] == VKUIKeyMove2D) [scene2DView moveObject:values[0] x:[values[2] doubleValue] y:[values[3] doubleValue]];
        else if ([action[0] unsignedCharValue] == VKUIKeyMove3D) {
            VK3DObject *object = sceneView.objectsByID[values[0]];
            if (object) object.position = VKVectorAdd(object.position, VKVectorMake([values[2] doubleValue], [values[3] doubleValue], [values[4] doubleValue]));
            sceneView.needsDisplay = YES;
        }
        else if ([action[0] unsignedCharValue] == VKUIKeynote) [strongSelf playInstrument:values[1] note:[values[2] unsignedCharValue] duration:[values[3] doubleValue]];
        else {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = values[1];
            VKProgramWindow *strongWindow = weakWindow;
            if (strongWindow) [alert beginSheetModalForWindow:strongWindow completionHandler:nil];
        }
    };
    [window center];
    [window makeKeyAndOrderFront:nil];
    [self.previewWindows addObject:window];
    if (self.previewWindows.count > 10) { [self.previewWindows.firstObject close]; [self.previewWindows removeObjectAtIndex:0]; }
    for (NSArray *action in startupActions) {
        NSArray *values = action[1];
        if ([action[0] unsignedCharValue] == VKUINote) [self playInstrument:values[0] note:[values[1] unsignedCharValue] duration:[values[2] doubleValue]];
        else [self playLocalSound:values[0]];
    }
}

- (void)playLocalSound:(NSString *)path {
    NSURL *base = self.fileURL.URLByDeletingLastPathComponent ?: [NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath isDirectory:YES];
    NSURL *url = [NSURL fileURLWithPath:path relativeToURL:base];
    NSSound *sound = [[NSSound alloc] initWithContentsOfFile:url.path byReference:YES];
    if (!sound || ![sound play]) { self.output.string = [NSString stringWithFormat:@"Could not play sound: %@", path]; return; }
    if (!self.activeSounds) self.activeSounds = [NSMutableArray array];
    [self.activeSounds addObject:sound];
    if (self.activeSounds.count > 200) [self.activeSounds removeObjectAtIndex:0];
}

- (void)playInstrument:(NSString *)instrument note:(UInt8)note duration:(NSTimeInterval)duration {
    if (!self.audioEngine) self.audioEngine = [[AVAudioEngine alloc] init];
    if (!self.instrumentSamplers) self.instrumentSamplers = [NSMutableDictionary dictionary];
    AVAudioUnitSampler *sampler = self.instrumentSamplers[instrument];
    NSError *error = nil;
    if (!sampler) {
        sampler = [[AVAudioUnitSampler alloc] init];
        [self.audioEngine attachNode:sampler];
        [self.audioEngine connect:sampler to:self.audioEngine.mainMixerNode format:nil];
        NSURL *bank = [NSURL fileURLWithPath:@"/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"];
        UInt8 program = [instrument isEqualToString:@"guitar"] ? 24 : 0;
        if (![sampler loadSoundBankInstrumentAtURL:bank program:program bankMSB:kAUSampler_DefaultMelodicBankMSB bankLSB:kAUSampler_DefaultBankLSB error:&error]) {
            self.output.string = [NSString stringWithFormat:@"Could not load %@ instrument: %@", instrument, error.localizedDescription ?: @"unknown error"];
            [self.audioEngine detachNode:sampler];
            return;
        }
        self.instrumentSamplers[instrument] = sampler;
    }
    if (!self.audioEngine.isRunning && ![self.audioEngine startAndReturnError:&error]) {
        self.output.string = [NSString stringWithFormat:@"Could not start audio: %@", error.localizedDescription ?: @"unknown error"];
        return;
    }
    [sampler startNote:note withVelocity:100 onChannel:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [sampler stopNote:note onChannel:0]; });
}
- (NSString *)messageForButton:(VKActionButton *)sender {
    NSString *message = sender.message.length ? sender.message : @"Button clicked";
    BOOL first = YES;
    for (NSView *view in sender.superview.subviews) {
        if (![view isKindOfClass:[NSTextField class]] || ![(NSTextField *)view isEditable]) continue;
        NSTextField *input = (NSTextField *)view;
        if (first) { message = [message stringByReplacingOccurrencesOfString:@"{input}" withString:input.stringValue]; first = NO; }
        if (input.placeholderString.length) message = [message stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}", input.placeholderString] withString:input.stringValue];
    }
    return message;
}
- (void)showMessage:(VKActionButton *)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [self messageForButton:sender];
    [alert runModal];
}

- (void)showBuilder:(id)sender {
    (void)sender;
    if (self.builder) { self.builder.title = @"Vektkove UI Maker"; [self.builder makeKeyAndOrderFront:nil]; return; }
    self.builder = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 650) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.builder.title = @"Vektkove UI Maker";
    self.builder.releasedWhenClosed = NO;
    NSView *view = [[VKBackgroundView alloc] initWithFrame:self.builder.contentView.bounds];
    self.builder.contentView = view;
    NSTextField *titleLabel = [NSTextField labelWithString:@"Window title"];
    titleLabel.frame = NSMakeRect(20, 605, 100, 20);
    [view addSubview:titleLabel];
    self.builderTitle = field(@"My Vektkove App", NSMakeRect(120, 600, 250, 26));
    self.builderTitle.delegate = self;
    [view addSubview:self.builderTitle];
    NSTextField *sizeLabel = [NSTextField labelWithString:@"Width / height"];
    sizeLabel.frame = NSMakeRect(390, 605, 100, 20);
    [view addSubview:sizeLabel];
    self.builderWidth = field(@"480", NSMakeRect(490, 600, 70, 26));
    self.builderHeight = field(@"300", NSMakeRect(570, 600, 70, 26));
    self.builderWidth.delegate = self;
    self.builderHeight.delegate = self;
    [view addSubview:self.builderWidth]; [view addSubview:self.builderHeight];
    NSPopUpButton *shapePicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 550, 150, 26) pullsDown:NO];
    [shapePicker addItemsWithTitles:@[@"Add 3D shape", @"Box", @"Sphere", @"Cylinder", @"Cone", @"Torus", @"Plane"]];
    shapePicker.target = self;
    shapePicker.action = @selector(add3DShape:);
    shapePicker.toolTip = @"Add a 3D primitive";
    [view addSubview:shapePicker];
    NSTextField *cameraLabel = [NSTextField labelWithString:@"Camera X / Y / Z"];
    cameraLabel.frame = NSMakeRect(190, 555, 110, 18);
    [view addSubview:cameraLabel];
    NSTextField *gravityLabel = [NSTextField labelWithString:@"Gravity X / Y / Z"];
    gravityLabel.frame = NSMakeRect(510, 555, 110, 18);
    [view addSubview:gravityLabel];
    NSMutableArray *cameraFields = [NSMutableArray array], *gravityFields = [NSMutableArray array];
    for (NSUInteger index = 0; index < 3; index++) {
        NSTextField *cameraField = field(index == 2 ? @"14" : @"0", NSMakeRect(305 + index * 60, 550, 52, 26));
        NSTextField *gravityField = field(@"0", NSMakeRect(625 + index * 60, 550, 52, 26));
        cameraField.delegate = self;
        gravityField.delegate = self;
        [cameraFields addObject:cameraField];
        [gravityFields addObject:gravityField];
        [view addSubview:cameraField];
        [view addSubview:gravityField];
    }
    self.builderCamera3D = cameraFields;
    self.builderGravity3D = gravityFields;
    NSButton *importModel = button(@"Import 3D Model", NSMakeRect(830, 548, 150, 30), self, @selector(importBuilderModel:));
    importModel.toolTip = @"Import a local model into the 3D scene";
    [view addSubview:importModel];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 90, 465, 440)];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.table.rowHeight = 28;
    NSArray *names = @[@"type", @"text", @"id", @"bind", @"x", @"y", @"width", @"height", @"message", @"z", @"depth", @"mass", @"bounce", @"vx", @"vy", @"vz", @"spin"];
    NSArray *widths = @[@70, @100, @75, @75, @45, @45, @55, @55, @145, @55, @55, @55, @60, @55, @55, @55, @55];
    for (NSUInteger index = 0; index < names.count; index++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:names[index]];
        column.title = [names[index] capitalizedString];
        column.width = [widths[index] doubleValue];
        column.editable = ![names[index] isEqualToString:@"type"];
        [self.table addTableColumn:column];
    }
    self.table.dataSource = self;
    self.table.delegate = self;
    scroll.documentView = self.table;
    [view addSubview:scroll];
    self.designerCanvas = [[VKDesignerCanvas alloc] initWithFrame:NSMakeRect(505, 90, 575, 440)];
    self.designerCanvas.elements = self.elements;
    self.designerCanvas.documentSize = NSMakeSize(480, 300);
    self.designerCanvas.selectedIndex = -1;
    self.designerCanvas.dragIndex = -1;
    self.designerCanvas.showsGrid = YES;
    self.designerCanvas.snapsToGrid = YES;
    self.designerCanvas.gridSize = 8;
    __weak VKApp *weakSelf = self;
    self.designerCanvas.selectionChanged = ^(NSInteger index) {
        VKApp *strongSelf = weakSelf;
        if (index >= 0) [strongSelf.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index] byExtendingSelection:NO];
        else [strongSelf.table deselectAll:nil];
    };
    self.designerCanvas.geometryChanged = ^(NSInteger index) {
        VKApp *strongSelf = weakSelf;
        if (index >= 0) [strongSelf.table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)index] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(4, 4)]];
        [strongSelf refreshBuilderCodePreview];
    };
    [view addSubview:self.designerCanvas];
    NSTextField *colorLabel = [NSTextField labelWithString:@"Color"];
    colorLabel.frame = NSMakeRect(670, 604, 50, 20);
    [view addSubview:colorLabel];
    self.designerColor = [[NSColorWell alloc] initWithFrame:NSMakeRect(718, 596, 58, 32)];
    self.designerColor.color = colorFromHex(@"#DCE7F5");
    self.designerColor.target = self;
    self.designerColor.action = @selector(changeDesignerColor:);
    self.designerColor.enabled = NO;
    [view addSubview:self.designerColor];
    self.designerGridSnap = [NSButton checkboxWithTitle:@"Snap to grid" target:self action:@selector(changeDesignerGrid:)];
    self.designerGridSnap.frame = NSMakeRect(790, 600, 110, 26);
    self.designerGridSnap.state = NSControlStateValueOn;
    self.designerGridSnap.toolTip = @"Show the canvas grid and snap positions and sizes to its spacing";
    [view addSubview:self.designerGridSnap];
    self.designerGridSizeLabel = [NSTextField labelWithString:@"8 pt"];
    self.designerGridSizeLabel.frame = NSMakeRect(902, 604, 42, 18);
    [view addSubview:self.designerGridSizeLabel];
    self.designerGridSize = [[NSStepper alloc] initWithFrame:NSMakeRect(946, 598, 19, 26)];
    self.designerGridSize.minValue = 4;
    self.designerGridSize.maxValue = 40;
    self.designerGridSize.increment = 4;
    self.designerGridSize.integerValue = 8;
    self.designerGridSize.target = self;
    self.designerGridSize.action = @selector(changeDesignerGrid:);
    self.designerGridSize.toolTip = @"Change grid spacing from 4 to 40 points";
    [view addSubview:self.designerGridSize];
    [view addSubview:button(@"Draw", NSMakeRect(980, 598, 100, 30), self, @selector(showBuilderCode:))];
    NSArray *titles = @[@"+ Label", @"+ Input", @"+ Button", @"Remove", @"Import Sound", @"Clear Sounds", @"Duplicate", @"Preview", @"Apply Code"];
    NSArray *actions = @[@"addLabel:", @"addInput:", @"addButton:", @"removeElement:", @"importBuilderSound:", @"clearBuilderSounds:", @"duplicateElement:", @"previewBuilder:", @"useBuilder:"];
    NSArray *positions = @[@20, @110, @200, @295, @385, @500, @615, @840, @930];
    NSArray *buttonWidths = @[@85, @85, @90, @85, @110, @110, @95, @85, @150];
    for (NSUInteger index = 0; index < titles.count; index++) [view addSubview:button(titles[index], NSMakeRect([positions[index] doubleValue], 40, [buttonWidths[index] doubleValue], 30), self, NSSelectorFromString(actions[index]))];
    self.builderTemplates = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(715, 40, 120, 30) pullsDown:NO];
    [self.builderTemplates addItemWithTitle:@"Starter layouts"];
    for (NSDictionary *definition in [self builderTemplateDefinitions]) [self.builderTemplates addItemWithTitle:definition[@"name"]];
    self.builderTemplates.target = self;
    self.builderTemplates.action = @selector(applyBuilderTemplate:);
    self.builderTemplates.toolTip = @"Create a common starter layout";
    [view addSubview:self.builderTemplates];
    [self.builder center];
    [self.builder makeKeyAndOrderFront:nil];
}

- (void)show3DEditor:(id)sender {
    [self showBuilder:sender];
    if (!self.elements.count) {
        [self.builderTemplates selectItemWithTitle:@"3D Scene"];
        [self applyBuilderTemplate:nil];
    }
    self.builder.title = @"Vektkove 3D Editor";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.manualTable) return (NSInteger)MIN((NSUInteger)500, self.manualCount - MIN(self.manualCount, self.manualPage * 500));
    return (NSInteger)self.elements.count;
}
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (tableView == self.manualTable) {
        NSString *keyword = [self manualKeywordAtPosition:self.manualPage * 500 + (NSUInteger)row];
        if ([column.identifier isEqualToString:@"keyword"]) return keyword;
        if ([column.identifier isEqualToString:@"category"]) return [VKEngine categoryForKeyword:keyword];
        return [VKEngine helpForKeyword:keyword];
    }
    return self.elements[(NSUInteger)row][column.identifier];
}
- (BOOL)tableView:(NSTableView *)tableView shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if ([column.identifier isEqualToString:@"bind"] && [self.elements[(NSUInteger)row][@"type"] isEqualToString:@"button"]) return NO;
    return column.isEditable;
}
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if ([column.identifier isEqualToString:@"bind"] && [self.elements[(NSUInteger)row][@"type"] isEqualToString:@"button"]) return;
    self.elements[(NSUInteger)row][column.identifier] = [value description];
    [self refreshDesignerCanvas];
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != self.table) return;
    NSInteger selected = self.table.selectedRow;
    self.designerCanvas.selectedIndex = selected;
    self.designerColor.enabled = selected >= 0 && (NSUInteger)selected < self.elements.count;
    if (self.designerColor.enabled) self.designerColor.color = colorFromHex(self.elements[(NSUInteger)selected][@"color"]);
    self.designerCanvas.needsDisplay = YES;
}
- (void)refreshDesignerCanvas {
    CGFloat width = self.builderWidth.doubleValue, height = self.builderHeight.doubleValue;
    if (width > 0 && width <= 10000 && height > 0 && height <= 10000) self.designerCanvas.documentSize = NSMakeSize(width, height);
    self.designerCanvas.needsDisplay = YES;
    [self refreshBuilderCodePreview];
}
- (void)changeDesignerGrid:(id)sender {
    (void)sender;
    self.designerCanvas.snapsToGrid = self.designerGridSnap.state == NSControlStateValueOn;
    self.designerCanvas.gridSize = self.designerGridSize.doubleValue;
    self.designerGridSizeLabel.stringValue = [NSString stringWithFormat:@"%.0f pt", self.designerCanvas.gridSize];
    self.designerCanvas.needsDisplay = YES;
}
- (void)changeDesignerColor:(id)sender {
    (void)sender;
    NSInteger selected = self.table.selectedRow;
    if (selected < 0 || (NSUInteger)selected >= self.elements.count) return;
    NSColor *color = [self.designerColor.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) return;
    self.elements[(NSUInteger)selected][@"color"] = [NSString stringWithFormat:@"#%02X%02X%02X", (unsigned)lround(color.redComponent * 255), (unsigned)lround(color.greenComponent * 255), (unsigned)lround(color.blueComponent * 255)];
    [self refreshDesignerCanvas];
}
- (NSString *)uniqueBuilderID:(NSString *)base {
    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (NSDictionary *element in self.elements) if ([element[@"id"] length]) [existing addObject:element[@"id"]];
    NSString *candidate = base;
    NSUInteger suffix = 2;
    while ([existing containsObject:candidate]) candidate = [NSString stringWithFormat:@"%@_%lu", base, (unsigned long)suffix++];
    return candidate;
}
- (void)addType:(NSString *)type {
    NSString *title = [type isEqualToString:@"label"] ? @"New label" : [type isEqualToString:@"input"] ? @"Enter text" : @"Click me";
    NSUInteger number = self.elements.count + 1;
    NSString *identifier = [self uniqueBuilderID:[NSString stringWithFormat:@"%@%lu", type, (unsigned long)number]];
    CGFloat y = MIN(MAX(0, self.builderHeight.doubleValue - 30), 20 + self.elements.count * 45.0);
    [self.elements addObject:[@{@"type":type, @"text":title, @"id":identifier, @"bind":@"", @"x":@"20", @"y":[NSString stringWithFormat:@"%.0f", y], @"width":@"180", @"height":@"30", @"message":@"Hello!", @"color":@"#DCE7F5"} mutableCopy]];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:self.elements.count - 1] byExtendingSelection:NO];
    [self refreshDesignerCanvas];
}
- (void)addLabel:(id)sender { (void)sender; [self addType:@"label"]; }
- (void)addInput:(id)sender { (void)sender; [self addType:@"input"]; }
- (void)addButton:(id)sender { (void)sender; [self addType:@"button"]; }
- (void)add3DShape:(NSPopUpButton *)picker {
    NSInteger selected = picker.indexOfSelectedItem;
    NSArray *types = @[@"box3d", @"sphere3d", @"cylinder3d", @"cone3d", @"torus3d", @"plane3d"];
    if (selected < 1 || selected > (NSInteger)types.count) return;
    NSString *type = types[(NSUInteger)selected - 1];
    NSString *identifier = [self uniqueBuilderID:type];
    CGFloat x = MAX(0, (self.builderWidth.doubleValue - 64) / 2);
    CGFloat y = MAX(0, (self.builderHeight.doubleValue - 64) / 2);
    [self.elements addObject:[@{@"type":type, @"text":picker.selectedItem.title, @"id":identifier, @"bind":@"", @"x":[NSString stringWithFormat:@"%.0f", x], @"y":[NSString stringWithFormat:@"%.0f", y], @"width":@"64", @"height":@"64", @"z":@"0", @"depth":@"64", @"mass":@"", @"bounce":@"0.5", @"vx":@"0", @"vy":@"0", @"vz":@"0", @"spin":@"", @"message":@"", @"color":@"#38A6D8"} mutableCopy]];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:self.elements.count - 1] byExtendingSelection:NO];
    [self refreshDesignerCanvas];
    [picker selectItemAtIndex:0];
}
- (BOOL)addImportedModelAtURL:(NSURL *)url error:(NSString **)error {
    if (!VKImportMesh(url, error)) return NO;
    NSString *identifier = [self uniqueBuilderID:@"model3d"];
    CGFloat x = MAX(0, (self.builderWidth.doubleValue - 64) / 2);
    CGFloat y = MAX(0, (self.builderHeight.doubleValue - 64) / 2);
    [self.elements addObject:[@{@"type":@"model3d", @"text":url.lastPathComponent, @"id":identifier, @"path":url.path, @"bind":@"", @"x":[NSString stringWithFormat:@"%.0f", x], @"y":[NSString stringWithFormat:@"%.0f", y], @"width":@"64", @"height":@"64", @"z":@"0", @"depth":@"64", @"mass":@"", @"bounce":@"0.5", @"vx":@"0", @"vy":@"0", @"vz":@"0", @"spin":@"", @"message":@"", @"color":@"#B8C6D0"} mutableCopy]];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:self.elements.count - 1] byExtendingSelection:NO];
    [self refreshDesignerCanvas];
    return YES;
}
- (void)importBuilderModel:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Import 3D Model";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *error = nil;
    if (![self addImportedModelAtURL:panel.URL error:&error]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could not import 3D model";
        alert.informativeText = error ?: @"The selected model is not supported.";
        [alert runModal];
    }
}
- (void)removeElement:(id)sender { (void)sender; NSInteger row = self.table.selectedRow; if (row >= 0 && row < (NSInteger)self.elements.count) { [self.elements removeObjectAtIndex:(NSUInteger)row]; [self.table reloadData]; [self.table deselectAll:nil]; [self refreshDesignerCanvas]; } }
- (void)duplicateElement:(id)sender {
    (void)sender;
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.elements.count) return;
    NSMutableDictionary *copy = [self.elements[(NSUInteger)row] mutableCopy];
    copy[@"id"] = [self uniqueBuilderID:[NSString stringWithFormat:@"%@_copy", copy[@"id"]]];
    CGFloat offset = self.designerCanvas.snapsToGrid ? self.designerCanvas.gridSize : 8;
    CGFloat width = self.builderWidth.doubleValue, height = self.builderHeight.doubleValue;
    CGFloat x = [copy[@"x"] doubleValue], y = [copy[@"y"] doubleValue];
    copy[@"x"] = [NSString stringWithFormat:@"%.0f", MIN(MAX(0, width - [copy[@"width"] doubleValue]), x + offset)];
    copy[@"y"] = [NSString stringWithFormat:@"%.0f", MIN(MAX(0, height - [copy[@"height"] doubleValue]), y + offset)];
    [self.elements insertObject:copy atIndex:(NSUInteger)row + 1];
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row + 1] byExtendingSelection:NO];
    [self refreshDesignerCanvas];
}

- (void)importBuilderSound:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeAudio];
    panel.allowsMultipleSelection = YES;
    if ([panel runModal] != NSModalResponseOK) return;
    for (NSURL *url in panel.URLs) if (![self.builderSoundPaths containsObject:url.path]) [self.builderSoundPaths addObject:url.path];
    [self refreshBuilderCodePreview];
}
- (void)clearBuilderSounds:(id)sender { (void)sender; [self.builderSoundPaths removeAllObjects]; [self refreshBuilderCodePreview]; }

- (NSArray<NSDictionary *> *)builderTemplateDefinitions {
    static NSArray *definitions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        definitions = @[
            @{ @"name":@"2D Game", @"game2d":@YES},
            @{@"name":@"Welcome", @"headline":@"Welcome to your app", @"fields":@[], @"buttons":@[@"Continue"]},
            @{@"name":@"Sign In", @"headline":@"Welcome back", @"fields":@[@"Email", @"Password"], @"buttons":@[@"Sign in"]},
            @{@"name":@"Sign Up", @"headline":@"Create your account", @"fields":@[@"Name", @"Email", @"Password"], @"buttons":@[@"Create account"]},
            @{@"name":@"Contact Form", @"headline":@"Send us a message", @"fields":@[@"Name", @"Email", @"Subject", @"Message"], @"buttons":@[@"Send"]},
            @{@"name":@"Feedback", @"headline":@"How did we do?", @"fields":@[@"Your feedback"], @"buttons":@[@"Submit", @"Cancel"]},
            @{@"name":@"Search", @"headline":@"Find what you need", @"fields":@[@"Search terms"], @"buttons":@[@"Search", @"Clear"]},
            @{@"name":@"Settings", @"headline":@"Preferences", @"fields":@[@"Theme", @"Language", @"Notifications"], @"buttons":@[@"Save", @"Cancel"]},
            @{@"name":@"Calculator", @"headline":@"Quick calculator", @"fields":@[@"First number", @"Second number"], @"buttons":@[@"Add", @"Subtract", @"Multiply", @"Divide"]},
            @{@"name":@"Counter", @"headline":@"Counter", @"fields":@[@"Starting value"], @"buttons":@[@"-", @"Reset", @"+"]},
            @{@"name":@"Stopwatch", @"headline":@"00:00.0", @"fields":@[], @"buttons":@[@"Start", @"Lap", @"Reset"]},
            @{@"name":@"To-do List", @"headline":@"Today's tasks", @"fields":@[@"Add a task"], @"buttons":@[@"Add", @"Remove"]},
            @{@"name":@"Notes", @"headline":@"Quick notes", @"fields":@[@"Note title", @"Write a note"], @"buttons":@[@"Save", @"New note"]},
            @{@"name":@"Profile", @"headline":@"Your profile", @"fields":@[@"Display name", @"Email", @"About you"], @"buttons":@[@"Edit profile"]},
            @{@"name":@"Main Menu", @"headline":@"Choose an option", @"fields":@[], @"buttons":@[@"New", @"Open", @"Settings", @"Quit"]},
            @{@"name":@"Quiz", @"headline":@"Question 1", @"fields":@[@"Your answer"], @"buttons":@[@"Check", @"Next"]},
            @{@"name":@"Tip Calculator", @"headline":@"Split a bill", @"fields":@[@"Bill amount", @"Tip percent", @"Number of people"], @"buttons":@[@"Calculate"]},
            @{@"name":@"Temperature", @"headline":@"Temperature converter", @"fields":@[@"Degrees"], @"buttons":@[@"Celsius to Fahrenheit", @"Fahrenheit to Celsius"]},
            @{@"name":@"Unit Converter", @"headline":@"Convert a measurement", @"fields":@[@"Value", @"From unit", @"To unit"], @"buttons":@[@"Convert"]},
            @{@"name":@"Music Player", @"headline":@"Now playing", @"fields":@[@"Track name"], @"buttons":@[@"Previous", @"Play", @"Next"]},
            @{@"name":@"Dashboard", @"headline":@"Overview", @"fields":@[@"Search dashboard"], @"buttons":@[@"Refresh", @"Reports", @"Help"]},
            @{ @"name":@"3D Scene", @"game3d":@YES}
        ];
    });
    return definitions;
}
- (void)applyBuilderTemplate:(id)sender {
    (void)sender;
    NSInteger selected = self.builderTemplates.indexOfSelectedItem;
    NSArray *definitions = [self builderTemplateDefinitions];
    if (selected <= 0 || selected > (NSInteger)definitions.count) return;
    NSDictionary *definition = definitions[(NSUInteger)selected - 1];
    if ([definition[@"game2d"] boolValue]) {
        self.builderTitle.stringValue = @"2D Game";
        self.builderWidth.stringValue = @"480";
        self.builderHeight.stringValue = @"300";
        [self.elements removeAllObjects];
        [self.elements addObjectsFromArray:@[
            [@{@"type":@"circle2d", @"text":@"Player", @"id":@"player", @"bind":@"", @"x":@"56", @"y":@"128", @"width":@"36", @"height":@"36", @"message":@"", @"color":@"#32C8B2"} mutableCopy],
            [@{@"type":@"rect2d", @"text":@"Orb", @"id":@"orb", @"bind":@"", @"x":@"328", @"y":@"96", @"width":@"30", @"height":@"30", @"message":@"", @"color":@"#FF7059"} mutableCopy]
        ]];
        [self.table reloadData];
        [self.table deselectAll:nil];
        self.designerCanvas.selectedIndex = -1;
        [self refreshDesignerCanvas];
        [self.builderTemplates selectItemAtIndex:0];
        return;
    }
    if ([definition[@"game3d"] boolValue]) {
        self.builderTitle.stringValue = @"3D Scene";
        self.builderWidth.stringValue = @"640";
        self.builderHeight.stringValue = @"480";
        [self.elements removeAllObjects];
        NSArray *types = @[@"box3d", @"sphere3d", @"cylinder3d", @"cone3d", @"torus3d", @"plane3d"];
        NSArray *colors = @[@"#F15B40", @"#38A6D8", @"#54B87A", @"#F3B63F", @"#AC72C8", @"#7695A8"];
        for (NSUInteger index = 0; index < types.count; index++) {
            [self.elements addObject:[@{@"type":types[index], @"text":types[index], @"id":types[index], @"bind":@"", @"x":[NSString stringWithFormat:@"%lu", (unsigned long)(80 + (index % 3) * 180)], @"y":[NSString stringWithFormat:@"%lu", (unsigned long)(80 + (index / 3) * 180)], @"width":@"64", @"height":@"64", @"z":@"0", @"depth":@"64", @"mass":@"", @"bounce":@"0.5", @"vx":@"0", @"vy":@"0", @"vz":@"0", @"spin":@"", @"message":@"", @"color":colors[index]} mutableCopy]];
        }
        [self.table reloadData];
        [self.table deselectAll:nil];
        self.designerCanvas.selectedIndex = -1;
        [self refreshDesignerCanvas];
        [self.builderTemplates selectItemAtIndex:0];
        return;
    }
    NSArray *fields = definition[@"fields"], *actions = definition[@"buttons"];
    CGFloat height = MAX(300, 180 + fields.count * 50 + (actions.count > 2 ? 48 : 0));
    self.builderTitle.stringValue = definition[@"name"];
    self.builderWidth.stringValue = @"480";
    self.builderHeight.stringValue = [NSString stringWithFormat:@"%.0f", height];
    [self.elements removeAllObjects];
    [self.elements addObject:[@{@"type":@"label", @"text":definition[@"headline"], @"id":@"headline", @"bind":@"", @"x":@"24", @"y":@"24", @"width":@"432", @"height":@"34", @"message":@"", @"color":@"#DCE7F5"} mutableCopy]];
    for (NSUInteger index = 0; index < fields.count; index++) {
        NSString *identifier = [NSString stringWithFormat:@"input%lu", (unsigned long)index + 1];
        [self.elements addObject:[@{@"type":@"input", @"text":fields[index], @"id":identifier, @"bind":@"", @"x":@"24", @"y":[NSString stringWithFormat:@"%lu", (unsigned long)(76 + index * 50)], @"width":@"432", @"height":@"34", @"message":@"", @"color":@"#DCE7F5"} mutableCopy]];
    }
    CGFloat buttonWidth = (432 - MAX(0, (CGFloat)(actions.count - 1) * 8)) / MAX(1, actions.count);
    CGFloat buttonY = height - 58;
    for (NSUInteger index = 0; index < actions.count; index++) {
        [self.elements addObject:[@{@"type":@"button", @"text":actions[index], @"id":[NSString stringWithFormat:@"button%lu", (unsigned long)index + 1], @"bind":@"", @"x":[NSString stringWithFormat:@"%.0f", 24 + index * (buttonWidth + 8)], @"y":[NSString stringWithFormat:@"%.0f", buttonY], @"width":[NSString stringWithFormat:@"%.0f", buttonWidth], @"height":@"34", @"message":[NSString stringWithFormat:@"%@ selected", actions[index]], @"color":@"#DCE7F5"} mutableCopy]];
    }
    [self.table reloadData];
    [self.table deselectAll:nil];
    self.designerCanvas.selectedIndex = -1;
    [self refreshDesignerCanvas];
    [self.builderTemplates selectItemAtIndex:0];
}

- (NSString *)builderSource {
    NSMutableOrderedSet<NSString *> *boundNames = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *element in self.elements) if ([element[@"bind"] length]) [boundNames addObject:element[@"bind"]];
    BOOL hasGame2D = [self.elements indexOfObjectPassingTest:^BOOL(NSDictionary *element, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        return [element[@"type"] isEqualToString:@"rect2d"] || [element[@"type"] isEqualToString:@"circle2d"];
    }] != NSNotFound;
    BOOL hasGame3D = [self.elements indexOfObjectPassingTest:^BOOL(NSDictionary *element, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        NSString *type = element[@"type"];
        return [type isEqualToString:@"camera3d"] || [type isEqualToString:@"light3d"] || [type isEqualToString:@"box3d"] || [type isEqualToString:@"sphere3d"] || [type isEqualToString:@"cylinder3d"] || [type isEqualToString:@"cone3d"] || [type isEqualToString:@"torus3d"] || [type isEqualToString:@"plane3d"] || [type isEqualToString:@"model3d"];
    }] != NSNotFound;
    NSMutableString *source = [NSMutableString string];
    for (NSString *name in boundNames) [source appendFormat:@"text %@ \"\"\n", name];
    if (hasGame2D) [source appendString:@"set frames 0\nset hits 0\n"];
    [source appendString:@"import ui\n"];
    [source appendFormat:@"window %@ %@ %@\n", quote(self.builderTitle.stringValue), self.builderWidth.stringValue, self.builderHeight.stringValue];
    if (hasGame2D) [source appendFormat:@"ui_scene2d 0 0 %@ %@\n", self.builderWidth.stringValue, self.builderHeight.stringValue];
    if (hasGame3D) {
        [source appendFormat:@"ui_scene3d 0 0 %@ %@\nui_camera3d %@ %@ %@\n", self.builderWidth.stringValue, self.builderHeight.stringValue, self.builderCamera3D[0].stringValue, self.builderCamera3D[1].stringValue, self.builderCamera3D[2].stringValue];
        if (self.builderGravity3D[0].doubleValue != 0 || self.builderGravity3D[1].doubleValue != 0 || self.builderGravity3D[2].doubleValue != 0)
            [source appendFormat:@"ui_gravity3d %@ %@ %@\n", self.builderGravity3D[0].stringValue, self.builderGravity3D[1].stringValue, self.builderGravity3D[2].stringValue];
    }
    for (NSString *path in self.builderSoundPaths) [source appendFormat:@"ui_sound %@\n", quote(path)];
    for (NSDictionary *element in self.elements) {
        NSString *type = element[@"type"];
        if ([type isEqualToString:@"circle2d"]) {
            [source appendFormat:@"ui_circle2d %@ %@ %@ %@ %@\n", quote(element[@"id"]), element[@"x"], element[@"y"], element[@"width"], quote(element[@"color"])];
            [source appendFormat:@"ui_physics2d %@ 0 0.25\n", quote(element[@"id"])];
            continue;
        }
        if ([type isEqualToString:@"rect2d"]) {
            [source appendFormat:@"ui_rect2d %@ %@ %@ %@ %@ %@\n", quote(element[@"id"]), element[@"x"], element[@"y"], element[@"width"], element[@"height"], quote(element[@"color"])];
            [source appendFormat:@"ui_physics2d %@ 1 0.8\n", quote(element[@"id"])];
            continue;
        }
        if ([@[@"box3d", @"sphere3d", @"cylinder3d", @"cone3d", @"torus3d", @"plane3d", @"model3d"] containsObject:type]) {
            double width = [element[@"width"] doubleValue] / 40.0;
            double height = [element[@"height"] doubleValue] / 40.0;
            double depth = [element[@"depth"] doubleValue] / 40.0;
            double x = ([element[@"x"] doubleValue] + [element[@"width"] doubleValue] / 2 - self.builderWidth.doubleValue / 2) / 40.0;
            double y = (self.builderHeight.doubleValue / 2 - [element[@"y"] doubleValue] - [element[@"height"] doubleValue] / 2) / 40.0;
            double z = [element[@"z"] doubleValue];
            NSString *color = quote(element[@"color"]);
            if ([type isEqualToString:@"model3d"]) [source appendFormat:@"ui_mesh3d %@ %.4f %.4f %.4f %.4f %@\n", quote(element[@"path"]), x, y, z, [element[@"width"] doubleValue] / 64.0, color];
            else if ([type isEqualToString:@"box3d"]) [source appendFormat:@"ui_box3d %.4f %.4f %.4f %.4f %.4f %.4f %@\n", x, y, z, width, height, depth, color];
            else if ([type isEqualToString:@"sphere3d"]) [source appendFormat:@"ui_sphere3d %.4f %.4f %.4f %.4f %@\n", x, y, z, width / 2, color];
            else if ([type isEqualToString:@"cylinder3d"]) [source appendFormat:@"ui_cylinder3d %.4f %.4f %.4f %.4f %.4f %@\n", x, y, z, width / 2, height, color];
            else if ([type isEqualToString:@"cone3d"]) [source appendFormat:@"ui_cone3d %.4f %.4f %.4f 0 %.4f %.4f %@\n", x, y, z, width / 2, height, color];
            else if ([type isEqualToString:@"torus3d"]) [source appendFormat:@"ui_torus3d %.4f %.4f %.4f %.4f %.4f %@\n", x, y, z, width / 2, height / 8, color];
            else [source appendFormat:@"ui_plane3d %.4f %.4f %.4f %.4f %.4f %@\n", x, y, z, width, height, color];
            [source appendFormat:@"ui_id %@\n", quote(element[@"id"])];
            if ([element[@"mass"] length]) [source appendFormat:@"ui_physics3d %@ %@ %@\n", quote(element[@"id"]), element[@"mass"], element[@"bounce"]];
            if ([element[@"vx"] doubleValue] != 0 || [element[@"vy"] doubleValue] != 0 || [element[@"vz"] doubleValue] != 0) [source appendFormat:@"ui_velocity3d %@ %@ %@ %@\n", quote(element[@"id"]), element[@"vx"] ?: @"0", element[@"vy"] ?: @"0", element[@"vz"] ?: @"0"];
            if ([element[@"spin"] length]) [source appendFormat:@"ui_spin3d %@ %@\n", quote(element[@"id"]), element[@"spin"]];
            continue;
        }
        if ([type isEqualToString:@"camera3d"]) {
            [source appendFormat:@"ui_camera3d %@ %@ %@\n", element[@"x"], element[@"y"], element[@"z"]];
            continue;
        }
        if ([type isEqualToString:@"light3d"]) {
            [source appendFormat:@"ui_light3d %@ %@ %@ %@\n", element[@"x"], element[@"y"], element[@"z"], element[@"width"]];
            continue;
        }
        [source appendFormat:@"ui_color %@\n", quote(element[@"color"])];
        [source appendFormat:@"ui_%@ %@ %@ %@ %@ %@", type, quote(element[@"text"]), element[@"x"], element[@"y"], element[@"width"], element[@"height"]];
        if ([type isEqualToString:@"button"]) [source appendFormat:@" %@", quote(element[@"message"] )];
        [source appendFormat:@"\nui_id %@\n", quote(element[@"id"] ?: @"")];
        if ([element[@"bind"] length]) [source appendFormat:@"ui_bind %@ %@\n", quote(element[@"id"]), element[@"bind"]];
    }
    if (hasGame2D) {
        [source appendString:@"ui_gravity2d 0 180\n"];
        for (NSDictionary *element in self.elements) {
            if ([element[@"id"] isEqualToString:@"player"] && [element[@"type"] isEqualToString:@"circle2d"]) {
                [source appendString:@"ui_keymove2d \"player\" \"a\" -12 0\nui_keymove2d \"player\" \"d\" 12 0\nui_keymove2d \"player\" \"w\" 0 -12\nui_keymove2d \"player\" \"s\" 0 12\n"];
            }
            if ([element[@"id"] isEqualToString:@"orb"] && [element[@"type"] isEqualToString:@"rect2d"])
                [source appendString:@"ui_velocity2d \"orb\" -38 27\n"];
        }
            [source appendString:@"ui_frame2d\nadd frames 1\nif $collision hit\njump frame_done\nlabel hit\nadd hits 1\nui_force2d \"orb\" -40 -18\nlabel frame_done\nui_end_frame2d\n"];
    }
    [source appendString:@"halt\n"];
    return source;
}
- (NSString *)lineNumberedSource:(NSString *)source {
    NSArray<NSString *> *lines = [source componentsSeparatedByString:@"\n"];
    NSUInteger count = lines.count - (lines.lastObject.length == 0 ? 1 : 0);
    NSMutableString *numbered = [NSMutableString string];
    for (NSUInteger index = 0; index < count; index++) [numbered appendFormat:@"%4lu  %@\n", (unsigned long)index + 1, lines[index]];
    return numbered;
}
- (void)refreshBuilderCodePreview {
    if (!self.builderCodeView) return;
    NSString *numbered = [self lineNumberedSource:[self builderSource]];
    NSUInteger selection = MIN(self.builderCodeView.selectedRange.location, numbered.length);
    self.builderCodeView.string = numbered;
    [self.builderCodeView setSelectedRange:NSMakeRange(selection, 0)];
    NSUInteger lines = [numbered componentsSeparatedByString:@"\n"].count - 1;
    self.builderCodeStatus.stringValue = [NSString stringWithFormat:@"Line 1 / %lu", (unsigned long)MAX(1, lines)];
}
- (BOOL)applyBuilderSourceToEditor {
    NSString *source = [self builderSource];
    NSString *error = nil;
    NSData *code = [VKEngine compile:source error:&error];
    NSMutableArray *ui = [NSMutableArray array];
    if (!code || ![VKEngine run:code ui:ui error:&error]) { NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = error ?: @"Invalid UI."; [alert runModal]; return NO; }
    if (![self confirmDiscard]) return NO;
    self.editor.string = source; self.fileURL = nil; self.savedSource = @""; self.window.documentEdited = YES;
    [self updateSourceLabel];
    self.output.string = @"UI source added to the editor. Save it as a .vk file.";
    [self.window makeKeyAndOrderFront:nil];
    return YES;
}
- (void)showBuilderCode:(id)sender {
    (void)sender;
    if (![self applyBuilderSourceToEditor]) return;
    if (!self.builderCodeWindow) {
        self.builderCodeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 640) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.builderCodeWindow.title = @"Drawn UI Source";
        self.builderCodeWindow.releasedWhenClosed = NO;
        NSView *content = [[VKBackgroundView alloc] initWithFrame:self.builderCodeWindow.contentView.bounds];
        self.builderCodeWindow.contentView = content;
        self.builderCodeStatus = [NSTextField labelWithString:@"Line 1"];
        self.builderCodeStatus.frame = NSMakeRect(20, 600, 220, 20);
        [content addSubview:self.builderCodeStatus];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, 860, 525)];
        scroll.borderType = NSBezelBorder;
        scroll.hasVerticalScroller = YES;
        scroll.hasHorizontalScroller = YES;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.builderCodeView = [[NSTextView alloc] initWithFrame:scroll.bounds];
        [self configureTextView:self.builderCodeView fontSize:13 inset:NSMakeSize(10, 8)];
        self.builderCodeView.editable = NO;
        self.builderCodeView.selectable = YES;
        self.builderCodeView.delegate = self;
        scroll.documentView = self.builderCodeView;
        [content addSubview:scroll];
    }
    [self refreshBuilderCodePreview];
    [self.builderCodeWindow center];
    [self.builderCodeWindow makeKeyAndOrderFront:nil];
}
- (void)textViewDidChangeSelection:(NSNotification *)notification {
    if (notification.object != self.builderCodeView) return;
    NSUInteger position = MIN(self.builderCodeView.selectedRange.location, self.builderCodeView.string.length);
    NSString *prefix = [self.builderCodeView.string substringToIndex:position];
    NSUInteger line = [[prefix componentsSeparatedByString:@"\n"] count];
    NSUInteger total = [[self.builderCodeView.string componentsSeparatedByString:@"\n"] count] - 1;
    self.builderCodeStatus.stringValue = [NSString stringWithFormat:@"Line %lu / %lu", (unsigned long)line, (unsigned long)MAX(1, total)];
}
- (void)previewBuilder:(id)sender {
    (void)sender;
    NSString *error = nil;
    NSData *code = [VKEngine compile:[self builderSource] error:&error];
    NSMutableArray *ui = [NSMutableArray array];
    if (!code || ![VKEngine run:code ui:ui error:&error]) { NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = error ?: @"Invalid UI."; [alert runModal]; return; }
    [self showUI:ui];
}
- (void)useBuilder:(id)sender {
    (void)sender;
    [self applyBuilderSourceToEditor];
}
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    if (!urls.count) return;
    if (self.editor) [self openSourceURL:urls.firstObject];
    else self.pendingURL = urls.firstObject;
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    if (window != self.window) return YES;
    self.discardApproved = [self confirmDiscard];
    return self.discardApproved;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { (void)sender; return (self.discardApproved || [self confirmDiscard]) ? NSTerminateNow : NSTerminateCancel; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--model-formats")) {
            for (NSString *extension in @[@"obj", @"fbx", @"stl", @"gltf", @"glb", @"step", @"stp", @"ydr", @"dff", @"txd", @"ytd"]) {
                printf("%s: %s\n", extension.UTF8String, [MDLAsset canImportFileExtension:extension] ? "available" : "unavailable");
            }
            return 0;
        }
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        VKApp *delegate = [[VKApp alloc] init];
#ifdef VEKTKOVE_LAUNCHER
        delegate.launcherMode = YES;
        if (argc > 1 && !strcmp(argv[1], "--stdin")) {
            NSData *source = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            delegate.incomingSource = [[NSString alloc] initWithData:source encoding:NSUTF8StringEncoding] ?: @"";
            if (argc > 2 && !strcmp(argv[2], "--batch")) {
                NSString *error = nil;
                NSData *code = [VKEngine compile:delegate.incomingSource error:&error];
                if (!code) { fprintf(stderr, "Compile error: %s\n", error.UTF8String); return 1; }
                NSString *output = [VKEngine run:code error:&error];
                if (!output) { fprintf(stderr, "Runtime error: %s\n", error.UTF8String); return 1; }
                printf("%s", output.UTF8String);
                return 0;
            }
        }
#endif
        application.delegate = delegate;
        if (argc > 1 && !strcmp(argv[1], "--self-test")) {
            NSURL *modelTestURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"obj"]]];
            NSData *modelTestData = [@"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n" dataUsingEncoding:NSUTF8StringEncoding];
            if (![modelTestData writeToURL:modelTestURL options:NSDataWritingAtomic error:nil]) return 94;
            NSString *modelTestError = nil;
            NSArray *modelTestTriangles = VKImportMesh(modelTestURL, &modelTestError);
            [NSFileManager.defaultManager removeItemAtURL:modelTestURL error:nil];
            if (modelTestTriangles.count != 1) { NSLog(@"Model import self-test: %@", modelTestError); return 95; }
            NSURL *stlTestURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"stl"]]];
            NSMutableData *stlTestData = [NSMutableData dataWithLength:134];
            unsigned char *stlBytes = stlTestData.mutableBytes;
            stlBytes[80] = 1;
            float stlVertices[12] = {0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0};
            memcpy(stlBytes + 84, stlVertices, sizeof(stlVertices));
            if (![stlTestData writeToURL:stlTestURL options:NSDataWritingAtomic error:nil]) return 100;
            NSString *stlTestError = nil;
            NSArray *stlTestTriangles = VKImportMesh(stlTestURL, &stlTestError);
            [NSFileManager.defaultManager removeItemAtURL:stlTestURL error:nil];
            if (stlTestTriangles.count != 1) { NSLog(@"STL import self-test: %@", stlTestError); return 101; }
            NSSize normalRenderSize = VK3DRenderSize(640, 480, 2);
            NSSize largeRenderSize = VK3DRenderSize(10000, 10000, 2);
            VKVector3 crossing[] = {VKVectorMake(-1, 0, 0.05), VKVectorMake(1, 0, 1), VKVectorMake(0, 1, 1)};
            VKVector3 clipped[4];
            NSUInteger clippedCount = VKClipNearPlane(crossing, clipped, 0.1);
            if (clippedCount != 4) return 102;
            for (NSUInteger corner = 0; corner < clippedCount; corner++) if (clipped[corner].z < 0.1 - 1e-9) return 103;
            IUINT32 testPixels[16][16] = {{0}};
            float testDepth[16][16] = {{0}};
            IUINT32 *testPixelRows[16];
            float *testDepthRows[16];
            for (NSUInteger row = 0; row < 16; row++) { testPixelRows[row] = testPixels[row]; testDepthRows[row] = testDepth[row]; }
            device_t testDevice = {0};
            testDevice.width = 16; testDevice.height = 16; testDevice.framebuffer = testPixelRows;
            testDevice.zbuffer = testDepthRows; testDevice.render_state = RENDER_STATE_COLOR;
            NSPoint testTriangle[] = {NSMakePoint(1, 1), NSMakePoint(14, 1), NSMakePoint(1, 14)};
            double nearDepth[] = {2, 2, 2}, farDepth[] = {4, 4, 4};
            VKMiniRasterizeTriangle(&testDevice, testTriangle, nearDepth, 1, 0, 0, 16, 16);
            if (testPixels[3][3] != 0xff0000ffu || testDepth[3][3] <= 0) return 104;
            VKMiniRasterizeTriangle(&testDevice, testTriangle, farDepth, 0, 0, 1, 16, 16);
            if (testPixels[3][3] != 0xff0000ffu) return 105;
            NSUInteger largePixelCount = (NSUInteger)largeRenderSize.width * (NSUInteger)largeRenderSize.height;
            if (!NSEqualSizes(normalRenderSize, NSMakeSize(1280, 960)) ||
                largePixelCount * (4 + sizeof(float)) > (NSUInteger)2000 * 1024 * 1024 ||
                largePixelCount < (NSUInteger)250000000 ||
                !NSEqualSizes(VK3DRenderSize(0, 100, 2), NSZeroSize)) return 93;
            [delegate applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:application]];
            if (!application.applicationIconImage || !NSEqualSizes(application.applicationIconImage.size, NSMakeSize(512, 512))) return 75;
            NSString *snapshotAppearance = NSProcessInfo.processInfo.environment[@"VEKTKOVE_TEST_APPEARANCE"];
            if ([snapshotAppearance isEqualToString:@"light"]) delegate.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            else if ([snapshotAppearance isEqualToString:@"dark"]) delegate.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            NSString *snapshotProject = NSProcessInfo.processInfo.environment[@"VEKTKOVE_TEST_PROJECT"];
            if (snapshotProject.length && !delegate.launcherMode) [delegate setProjectFolder:[NSURL fileURLWithPath:snapshotProject isDirectory:YES]];
            if (NSProcessInfo.processInfo.environment[@"VEKTKOVE_TEST_MANUAL"] && !delegate.launcherMode) {
                NSSegmentedControl *tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Editor", @"Manual"] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
                tabs.selectedSegment = 1;
                [delegate changeTab:tabs];
            }
            NSString *snapshotPath = NSProcessInfo.processInfo.environment[@"VEKTKOVE_TEST_SNAPSHOT"];
            if (snapshotPath.length) {
                NSView *view = delegate.window.contentView;
                [view layoutSubtreeIfNeeded];
                [delegate.window displayIfNeeded];
                NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
                if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:snapshotPath atomically:YES]) return 28;
            }
            NSTextView *readableView = delegate.launcherMode ? delegate.output : delegate.editor;
            for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
                NSAppearance *appearance = [NSAppearance appearanceNamed:name];
                if (contrast(readableView.textColor, readableView.backgroundColor, appearance) < 4.5) return 26;
            }
            [delegate setReadableFontSize:20];
            if (readableView.font.pointSize != 20) return 27;
            [delegate setReadableFontSize:16];
            if (delegate.launcherMode) {
                delegate.incomingSource = @"test";
                delegate.editor.string = @"out \"hello\"\nhalt";
                [delegate runCode:nil];
                if (![delegate.output.string isEqualToString:@"hello\n"]) return 9;
                delegate.editor.string = @"invalid";
                [delegate runCode:nil];
                if (![delegate.output.string containsString:@"Error line 1: Unknown command: invalid"] || ![delegate.output.string containsString:@"1 error, 0 warnings."]) return 10;
                delegate.editor.string = @"set value 3\ndivide value 0";
                [delegate runCode:nil];
                if (![delegate.output.string containsString:@"Runtime error: Division by zero."]) return 11;
                delegate.editor.string = @"set unused 1\nout \"ok\"";
                [delegate runCode:nil];
                if (![delegate.output.string containsString:@"Warning line 1: Variable $unused is set but never used."] || ![delegate.output.string hasSuffix:@"ok\n"]) return 12;
                printf("VektkoveLauncher self-test passed\n");
                return 0;
            }
            NSArray *keyChecks = @[@[@(kVK_F1), @"f1"], @[@(kVK_F12), @"f12"], @[@(kVK_Home), @"home"], @[@(kVK_End), @"end"], @[@(kVK_PageUp), @"pageup"], @[@(kVK_PageDown), @"pagedown"], @[@(kVK_ForwardDelete), @"delete"], @[@(kVK_Help), @"insert"]];
            for (NSArray *check in keyChecks) {
                NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:delegate.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:[check[0] unsignedShortValue]];
                if (![programKeyForEvent(event) isEqualToString:check[1]]) return 58;
            }
            if (!testInstrumentRendering(@"piano") || !testInstrumentRendering(@"guitar")) return 59;
            [delegate filterManual];
            if (delegate.manualCount != VKEngine.keywordCount) return 29;
            delegate.manualPage = (delegate.manualCount - 1) / 500;
            [delegate reloadManualPage];
            if (![[delegate manualKeywordAtPosition:delegate.manualCount - 1] isEqualToString:@"window"]) return 49;
            if (delegate.manualTable.numberOfRows != (NSInteger)(delegate.manualCount - delegate.manualPage * 500)) return 30;
            delegate.manualSearch.stringValue = @"set_159860";
            [delegate filterManual];
            if (delegate.manualCount != 0 || [VKEngine compile:@"set_159860 n" error:nil]) return 31;
            delegate.manualSearch.stringValue = @"add_100000";
            [delegate filterManual];
            if (delegate.manualCount != 0 || [VKEngine compile:@"add_100000 n" error:nil] || [VKEngine compile:@"add_1 n" error:nil]) return 50;
            delegate.manualSearch.stringValue = @"divide_0";
            [delegate filterManual];
            if (delegate.manualCount != 0) return 32;
            delegate.manualSearch.stringValue = @"subtract_1";
            [delegate filterManual];
            if (delegate.manualCount != 0) return 33;
            delegate.manualSearch.stringValue = @"";
            [delegate filterManual];
            NSNumberFormatter *keywordFormatter = [[NSNumberFormatter alloc] init];
            keywordFormatter.numberStyle = NSNumberFormatterDecimalStyle;
            NSString *keywordTotal = [keywordFormatter stringFromNumber:@(VKEngine.keywordCount)];
            if (delegate.manualCategory.numberOfItems != 6 || ![delegate.manualCategory.itemTitles[0] containsString:keywordTotal]) return 39;
            NSUInteger expectedLogic = 0, expectedText = 0, expectedUI = 0, expectedCode = 0;
            NSUInteger expectedMath = 0;
            for (NSUInteger index = 0; index < VKEngine.baseKeywordCount; index++) {
                NSString *category = [VKEngine categoryForKeyword:[VKEngine keywordAtIndex:index]];
                if ([category isEqualToString:@"Logic"]) expectedLogic++;
                else if ([category isEqualToString:@"Text"]) expectedText++;
                else if ([category isEqualToString:@"UI"]) expectedUI++;
                else if ([category isEqualToString:@"Code"]) expectedCode++;
                else if ([category isEqualToString:@"Math"]) expectedMath++;
            }
            if (expectedCode + expectedLogic + expectedMath + expectedText + expectedUI != VKEngine.keywordCount) return 40;
            NSNumberFormatter *testFormatter = [[NSNumberFormatter alloc] init];
            testFormatter.numberStyle = NSNumberFormatterDecimalStyle;
            [delegate.manualCategory selectItemWithTitle:[NSString stringWithFormat:@"Logic (%@)", [testFormatter stringFromNumber:@(expectedLogic)]]];
            [delegate filterManual];
            if (delegate.manualCount != expectedLogic || ![[VKEngine categoryForKeyword:[delegate manualKeywordAtPosition:0]] isEqualToString:@"Logic"]) return 41;
            delegate.manualSort.selectedSegment = 1;
            [delegate filterManual];
            NSString *previousKeyword = nil;
            for (NSUInteger index = 0; index < MIN(delegate.manualCount, (NSUInteger)100); index++) {
                NSString *keyword = [delegate manualKeywordAtPosition:index];
                if (previousKeyword && [previousKeyword compare:keyword options:NSLiteralSearch] == NSOrderedDescending) return 42;
                previousKeyword = keyword;
            }
            [delegate.manualCategory selectItemAtIndex:0];
            [delegate.manualSearch setStringValue:@"add_159"];
            [delegate.manualCategory selectItemWithTitle:[NSString stringWithFormat:@"Math (%@)", [testFormatter stringFromNumber:@(expectedMath)]]];
            [delegate filterManual];
            if (delegate.manualCount != 0) return 43;
            [delegate.manualCategory selectItemAtIndex:0];
            [delegate.manualSearch setStringValue:@""];
            delegate.manualSort.selectedSegment = 0;
            [delegate filterManual];
            delegate.manualSort.selectedSegment = 1;
            [delegate filterManual];
            if (![[VKEngine categoryForKeyword:[delegate manualKeywordAtPosition:expectedCode - 1]] isEqualToString:@"Code"]) return 44;
            if (![[VKEngine categoryForKeyword:[delegate manualKeywordAtPosition:expectedCode]] isEqualToString:@"Logic"]) return 45;
            if (![[VKEngine categoryForKeyword:[delegate manualKeywordAtPosition:expectedCode + expectedLogic]] isEqualToString:@"Math"]) return 46;
            delegate.manualSort.selectedSegment = 0;
            [delegate filterManual];
            NSString *previousAlpha = nil;
            for (NSUInteger index = 0; index < delegate.manualCount; index++) {
                NSString *keyword = [delegate manualKeywordAtPosition:index];
                if (previousAlpha && [previousAlpha compare:keyword options:NSLiteralSearch] == NSOrderedDescending) return 48;
                previousAlpha = keyword;
            }
            delegate.manualDimension.selectedSegment = 1;
            [delegate manualDimensionChanged:nil];
            if (![delegate.manualBaseMatches containsObject:@"ui_scene2d"] || ![delegate.manualBaseMatches containsObject:@"op_game_rect"] ||
                [delegate.manualBaseMatches containsObject:@"ui_scene3d"] || ![delegate.manualBaseMatches containsObject:@"window"]) return 109;
            if (![delegate.manualCategory.itemTitles[0] containsString:[testFormatter stringFromNumber:@(delegate.manualCount)]]) return 114;
            delegate.manualDimension.selectedSegment = 2;
            [delegate manualDimensionChanged:nil];
            if (![delegate.manualBaseMatches containsObject:@"ui_scene3d"] || ![delegate.manualBaseMatches containsObject:@"vk_box3d"] ||
                [delegate.manualBaseMatches containsObject:@"ui_scene2d"] || ![delegate.manualBaseMatches containsObject:@"ui_id"]) return 110;
            delegate.manualDimension.selectedSegment = 0;
            [delegate manualDimensionChanged:nil];
            BOOL has3DEditorButton = NO;
            for (NSView *subview in delegate.window.contentView.subviews) {
                if ([subview isKindOfClass:NSButton.class] && [(NSButton *)subview action] == @selector(show3DEditor:)) has3DEditorButton = YES;
            }
            if (!has3DEditorButton) return 111;
            [delegate show3DEditor:nil];
            if (delegate.elements.count != 6 || ![delegate.builder.title isEqualToString:@"Vektkove 3D Editor"] ||
                ![[delegate builderSource] containsString:@"ui_scene3d"]) return 112;
            delegate.elements[0][@"text"] = @"Keep this design";
            [delegate show3DEditor:nil];
            if (delegate.elements.count != 6 || ![delegate.elements[0][@"text"] isEqualToString:@"Keep this design"]) return 113;
            [delegate showBuilder:nil];
            if (![delegate.builder.title isEqualToString:@"Vektkove UI Maker"] || delegate.elements.count != 6) return 115;
            if (delegate.builderTemplates.numberOfItems != 23) return 67;
            [delegate.builderTemplates selectItemAtIndex:9];
            [delegate applyBuilderTemplate:nil];
            if (![delegate.builderTitle.stringValue isEqualToString:@"Calculator"] || delegate.elements.count != 7) return 68;
            [delegate.builderTemplates selectItemAtIndex:1];
            [delegate applyBuilderTemplate:nil];
            if (![delegate.builderTitle.stringValue isEqualToString:@"2D Game"] || delegate.elements.count != 2) return 78;
            NSString *gameSource = [delegate builderSource];
            if ([[[VKEngine diagnose:gameSource] componentsJoinedByString:@"\n"] containsString:@"Error "]) return 91;
            gameSource = [gameSource stringByReplacingOccurrencesOfString:@"if $collision hit" withString:@"if $collision_entered hit"];
            NSString *gameError = nil;
            NSData *gameCode = [VKEngine compile:gameSource error:&gameError];
            NSMutableArray *gameUI = [NSMutableArray array];
            if (!gameCode || ![VKEngine run:gameCode ui:gameUI error:&gameError]) return 79;
            [delegate showUI:gameUI];
            VK2DSceneView *gameView = nil;
            for (NSView *subview in delegate.previewWindows.lastObject.contentView.subviews) if ([subview isKindOfClass:VK2DSceneView.class]) gameView = (VK2DSceneView *)subview;
            if (!gameView || gameView.objects.count != 2 || ![gameView.objectsByID[@"player"] isKindOfClass:VK2DGameObject.class] || ![gameView.objectsByID[@"orb"] isKindOfClass:VK2DGameObject.class]) return 80;
            if (gameView.objectsByID[@"player"].mass != 0 || gameView.objectsByID[@"orb"].mass != 1 || gameView.frameCallback.count == 0) return 83;
            VKProgramWindow *gameWindow = (VKProgramWindow *)delegate.previewWindows.lastObject;
            if (![gameWindow.registeredKeys containsObject:@"a"] || ![gameWindow.registeredKeys containsObject:@"d"] || ![gameWindow.registeredKeys containsObject:@"w"] || ![gameWindow.registeredKeys containsObject:@"s"]) return 81;
            CGFloat playerX = gameView.objectsByID[@"player"].frame.origin.x;
            gameWindow.focusedKeyHandler(@"d");
            if (gameView.objectsByID[@"player"].frame.origin.x != playerX + 12) return 82;
            VK2DGameObject *player = gameView.objectsByID[@"player"], *orb = gameView.objectsByID[@"orb"];
            orb.frame = NSMakeRect(NSMaxX(player.frame) - 14, NSMidY(player.frame) - 14, 28, 28);
            orb.mass = 0;
            orb.velocity = CGPointMake(1000, 0);
            gameView.gravity = CGPointZero;
            gameView.lastFrameTime = CACurrentMediaTime() - 0.05;
            [gameView stepFrame];
            if (![gameView.frameVariables[@"collision"] boolValue] || ![gameView.frameVariables[@"collision_entered"] boolValue] || [gameView.frameVariables[@"collision_exited"] boolValue] || ![gameView.frameVariables[@"collision_a"] isEqualToString:@"player"] || ![gameView.frameVariables[@"collision_b"] isEqualToString:@"orb"] || ![gameView.frameVariables[@"collision_count"] isEqual:@1] || ![gameView.frameVariables[@"hits"] isEqual:@1] || [gameView.frameVariables[@"delta_time"] doubleValue] <= 0) return 84;
            gameView.lastFrameTime = CACurrentMediaTime() - 0.02;
            [gameView stepFrame];
            if (![gameView.frameVariables[@"collision"] boolValue] || [gameView.frameVariables[@"collision_entered"] boolValue] || [gameView.frameVariables[@"collision_exited"] boolValue] || ![gameView.frameVariables[@"hits"] isEqual:@1]) return 118;
            orb.frame = NSMakeRect(500, 300, 28, 28);
            gameView.lastFrameTime = CACurrentMediaTime() - 0.02;
            [gameView stepFrame];
            if ([gameView.frameVariables[@"collision"] boolValue] || [gameView.frameVariables[@"collision_entered"] boolValue] || ![gameView.frameVariables[@"collision_exited"] boolValue] || ![gameView.frameVariables[@"collision_a"] isEqualToString:@"player"] || ![gameView.frameVariables[@"collision_b"] isEqualToString:@"orb"]) return 119;
            [delegate.builderTemplates selectItemWithTitle:@"3D Scene"];
            [delegate applyBuilderTemplate:nil];
            if (delegate.elements.count != 6) return 85;
            delegate.elements[0][@"z"] = @"1";
            delegate.elements[0][@"mass"] = @"2";
            delegate.elements[0][@"bounce"] = @"0.75";
            delegate.elements[0][@"vx"] = @"1";
            delegate.elements[0][@"spin"] = @"3";
            delegate.builderGravity3D[1].stringValue = @"-2";
            NSPopUpButton *testShapePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [testShapePicker addItemsWithTitles:@[@"Add 3D shape", @"Box", @"Sphere", @"Cylinder", @"Cone", @"Torus", @"Plane"]];
            [testShapePicker selectItemAtIndex:2];
            [delegate add3DShape:testShapePicker];
            if (delegate.elements.count != 7 || ![delegate.elements.lastObject[@"id"] isEqualToString:@"sphere3d_2"]) return 90;
            NSData *starter3DCode = [VKEngine compile:[delegate builderSource] error:&gameError];
            NSMutableArray *starter3DUI = [NSMutableArray array];
            if (!starter3DCode || ![VKEngine run:starter3DCode ui:starter3DUI error:&gameError]) { NSLog(@"3D starter: %@", gameError); return 86; }
            [delegate showUI:starter3DUI];
            VK3DView *starter3DView = nil;
            for (NSView *subview in delegate.previewWindows.lastObject.contentView.subviews) if ([subview isKindOfClass:VK3DView.class]) starter3DView = (VK3DView *)subview;
            VK3DObject *starterBox = starter3DView.objectsByID[@"box3d"];
            if (starter3DView.objects.count != 7 || starter3DView.objectsByID.count != 7 || !starterBox.physicsEnabled || starterBox.mass != 2 || starterBox.restitution != 0.75 || starterBox.velocity.x != 1 || starterBox.position.z != 1 || starterBox.spinPeriod != 3 || starter3DView.gravity.y != -2) return 87;
            if (![modelTestData writeToURL:modelTestURL options:NSDataWritingAtomic error:nil]) return 96;
            NSString *builderModelError = nil;
            if (![delegate addImportedModelAtURL:modelTestURL error:&builderModelError]) { NSLog(@"Builder model import: %@", builderModelError); return 97; }
            NSData *importedModelCode = [VKEngine compile:[delegate builderSource] error:&gameError];
            NSMutableArray *importedModelUI = [NSMutableArray array];
            if (!importedModelCode || ![VKEngine run:importedModelCode ui:importedModelUI error:&gameError]) { NSLog(@"Imported model source: %@", gameError); return 98; }
            [delegate showUI:importedModelUI];
            VK3DView *importedModelView = nil;
            for (NSView *subview in delegate.previewWindows.lastObject.contentView.subviews) if ([subview isKindOfClass:VK3DView.class]) importedModelView = (VK3DView *)subview;
            VK3DObject *importedModel = importedModelView.objectsByID[@"model3d"];
            [NSFileManager.defaultManager removeItemAtURL:modelTestURL error:nil];
            if (!importedModel || importedModel.triangles.count != 1 || importedModelView.objects.count != 8) return 99;
            delegate.builderGravity3D[1].stringValue = @"0";
            NSString *physics3DSource = @"set hits 0\nimport ui\nwindow \"Physics\" 320 240\nui_scene3d 0 0 320 240\nui_sphere3d 0 0 0 1 \"#FF5533\"\nui_id \"first\"\nui_physics3d \"first\" 0 1\nui_sphere3d 1.5 0 0 1 \"#33AAFF\"\nui_id \"second\"\nui_physics3d \"second\" 1 1\nui_velocity3d \"second\" -1 0 0\nui_frame3d\nif $collision hit3d\njump done3d\nlabel hit3d\nadd hits 1\nui_force3d \"second\" 0 1 0\nlabel done3d\nui_end_frame3d\nhalt";
            physics3DSource = [physics3DSource stringByReplacingOccurrencesOfString:@"if $collision hit3d" withString:@"if $collision_entered hit3d"];
            if ([[[VKEngine diagnose:physics3DSource] componentsJoinedByString:@"\n"] containsString:@"Error "]) return 92;
            NSData *physics3DCode = [VKEngine compile:physics3DSource error:&gameError];
            NSMutableArray *physics3DUI = [NSMutableArray array];
            if (!physics3DCode || ![VKEngine run:physics3DCode ui:physics3DUI error:&gameError]) { NSLog(@"3D physics: %@", gameError); return 88; }
            [delegate showUI:physics3DUI];
            VK3DView *physics3DView = nil;
            for (NSView *subview in delegate.previewWindows.lastObject.contentView.subviews) if ([subview isKindOfClass:VK3DView.class]) physics3DView = (VK3DView *)subview;
            physics3DView.objectsByID[@"second"].mass = 0;
            physics3DView.objectsByID[@"second"].velocity = VKVectorMake(100, 0, 0);
            physics3DView.lastFrameTime = CACurrentMediaTime() - 0.02;
            [physics3DView stepFrame];
            if (!physics3DView || ![physics3DView.frameVariables[@"collision"] boolValue] || ![physics3DView.frameVariables[@"collision_entered"] boolValue] || [physics3DView.frameVariables[@"collision_exited"] boolValue] || ![physics3DView.frameVariables[@"collision_count"] isEqual:@1] || ![physics3DView.frameVariables[@"hits"] isEqual:@1]) return 89;
            physics3DView.lastFrameTime = CACurrentMediaTime() - 0.02;
            physics3DView.objectsByID[@"second"].velocity = VKVectorMake(0, 0, 0);
            [physics3DView stepFrame];
            if (![physics3DView.frameVariables[@"collision"] boolValue] || [physics3DView.frameVariables[@"collision_entered"] boolValue] || [physics3DView.frameVariables[@"collision_exited"] boolValue] || ![physics3DView.frameVariables[@"hits"] isEqual:@1]) return 120;
            physics3DView.objectsByID[@"second"].position = VKVectorMake(5, 0, 0);
            physics3DView.lastFrameTime = CACurrentMediaTime() - 0.02;
            [physics3DView stepFrame];
            if ([physics3DView.frameVariables[@"collision"] boolValue] || [physics3DView.frameVariables[@"collision_entered"] boolValue] || ![physics3DView.frameVariables[@"collision_exited"] boolValue] || ![physics3DView.frameVariables[@"collision_a"] isEqualToString:@"first"] || ![physics3DView.frameVariables[@"collision_b"] isEqualToString:@"second"]) return 121;
            VK3DView *shapeTest = [[VK3DView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
            VK3DObject *floorObject = [shapeTest addPrimitive:VKUIBox3D values:@[@0, @0, @0, @10, @1, @10, @"#808080"]];
            VK3DObject *ballObject = [shapeTest addPrimitive:VKUISphere3D values:@[@0, @3, @0, @0.5, @"#FF0000"]];
            floorObject.identifier = @"floor"; floorObject.mass = 0; floorObject.physicsEnabled = YES;
            ballObject.identifier = @"ball"; ballObject.mass = 0; ballObject.physicsEnabled = YES;
            shapeTest.lastFrameTime = CACurrentMediaTime() - 0.02;
            [shapeTest stepFrame];
            if (shapeTest.previousContacts.count != 0) return 122;
            ballObject.position = VKVectorMake(0, 0.9, 0);
            shapeTest.lastFrameTime = CACurrentMediaTime() - 0.02;
            [shapeTest stepFrame];
            if (shapeTest.previousContacts.count != 1) return 123;
            VKVector3 contactNormal;
            CGFloat contactDepth;
            if (!VK3DDetectCollision(floorObject, ballObject, &contactNormal, &contactDepth) || contactNormal.y < 0.99 || fabs(contactDepth - 0.1) > 0.001) return 124;
            if (!VK3DDetectCollision(ballObject, floorObject, &contactNormal, &contactDepth) || contactNormal.y > -0.99) return 125;
            ballObject.position = VKVectorMake(0, 0, 0);
            if (!VK3DDetectCollision(floorObject, ballObject, &contactNormal, &contactDepth) || contactNormal.y < 0.99 || fabs(contactDepth - 1) > 0.001) return 126;
            VK3DObject *boxObject = [shapeTest addPrimitive:VKUIBox3D values:@[@0, @3, @0, @1, @1, @1, @"#00FF00"]];
            if (VK3DDetectCollision(floorObject, boxObject, &contactNormal, &contactDepth)) return 127;
            boxObject.position = VKVectorMake(0, 0.9, 0);
            if (!VK3DDetectCollision(floorObject, boxObject, &contactNormal, &contactDepth) || contactNormal.y < 0.99 || fabs(contactDepth - 0.1) > 0.001) return 128;
            boxObject.position = VKVectorMake(6.5, 0, 0);
            boxObject.halfSize = VKVectorMake(2, 0.5, 0.2);
            if (!VK3DDetectCollision(floorObject, boxObject, &contactNormal, &contactDepth)) return 129;
            boxObject.spinPeriod = 100;
            boxObject.spinStart = CACurrentMediaTime() - 25;
            if (VK3DDetectCollision(floorObject, boxObject, &contactNormal, &contactDepth)) return 130;
            ballObject.position = VKVectorMake(0, 0.9, 0);
            ballObject.mass = 1;
            ballObject.velocity = VKVectorMake(0, -1, 0);
            shapeTest.lastFrameTime = CACurrentMediaTime() - 0.02;
            [shapeTest stepFrame];
            if (ballObject.position.y <= 0.9 || ballObject.velocity.y < 0) return 131;
            [delegate.elements removeAllObjects];
            [delegate.table reloadData];
            delegate.builderTitle.stringValue = @"My Vektkove App";
            delegate.builderWidth.stringValue = @"480";
            delegate.builderHeight.stringValue = @"300";
            [delegate.builderTemplates selectItemAtIndex:0];
            [delegate addLabel:nil]; [delegate addInput:nil]; [delegate addButton:nil];
            VKDesignerCanvas *canvas = delegate.designerCanvas;
            NSRect original = [canvas frameForElement:delegate.elements[0]];
            NSPoint start = [canvas convertPoint:NSMakePoint(NSMinX(original) + 5, NSMinY(original) + 5) toView:nil];
            NSPoint moved = [canvas convertPoint:NSMakePoint(NSMinX(original) + 35, NSMinY(original) + 25) toView:nil];
            NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:start modifierFlags:0 timestamp:0 windowNumber:delegate.builder.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
            NSEvent *drag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:moved modifierFlags:0 timestamp:0 windowNumber:delegate.builder.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
            [canvas mouseDown:down]; [canvas mouseDragged:drag]; [canvas mouseUp:drag];
            if ([delegate.elements[0][@"x"] integerValue] != 48 || [delegate.elements[0][@"y"] integerValue] != 40) return 54;
            NSRect afterMove = [canvas frameForElement:delegate.elements[0]];
            start = [canvas convertPoint:NSMakePoint(NSMaxX(afterMove) - 3, NSMaxY(afterMove) - 3) toView:nil];
            moved = [canvas convertPoint:NSMakePoint(NSMaxX(afterMove) + 17, NSMaxY(afterMove) + 7) toView:nil];
            down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:start modifierFlags:0 timestamp:0 windowNumber:delegate.builder.windowNumber context:nil eventNumber:3 clickCount:1 pressure:1];
            drag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:moved modifierFlags:0 timestamp:0 windowNumber:delegate.builder.windowNumber context:nil eventNumber:4 clickCount:1 pressure:1];
            [canvas mouseDown:down]; [canvas mouseDragged:drag]; [canvas mouseUp:drag];
            if ([delegate.elements[0][@"width"] integerValue] != 200 || [delegate.elements[0][@"height"] integerValue] != 40) return 55;
            delegate.designerColor.color = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1];
            [delegate changeDesignerColor:nil];
            if (![delegate.elements[0][@"color"] isEqualToString:@"#FF0000"]) return 56;
            [delegate tableView:delegate.table setObjectValue:@"Changed label" forTableColumn:delegate.table.tableColumns[1] row:0];
            [delegate duplicateElement:nil];
            if (delegate.elements.count != 4 || delegate.table.selectedRow != 1 || [delegate.elements[1][@"x"] integerValue] != 56 || ![delegate.elements[1][@"text"] isEqualToString:@"Changed label"]) return 66;
            NSString *error = nil;
            NSMutableArray *ui = [NSMutableArray array];
            NSData *code = [VKEngine compile:[delegate builderSource] error:&error];
            if (!code || ![VKEngine run:code ui:ui error:&error] || ui.count != 9) { fprintf(stderr, "UI self-test: %s\n", error.UTF8String); return 1; }
            if (![ui[1][1][5] isEqualToString:@"#FF0000"]) return 57;
            [delegate showUI:ui];
            if (delegate.previewWindows.lastObject.contentView.subviews.count != 4) return 2;
            NSTextField *label = delegate.previewWindows.lastObject.contentView.subviews[0];
            NSTextField *input = delegate.previewWindows.lastObject.contentView.subviews[2];
            VKActionButton *control = delegate.previewWindows.lastObject.contentView.subviews[3];
            if (![label.stringValue isEqualToString:@"Changed label"] || ![control.message isEqualToString:@"Hello!"]) return 3;
            input.stringValue = @"Ada";
            control.message = @"Hello {input} / {Enter text}";
            if (![[delegate messageForButton:control] isEqualToString:@"Hello Ada / Ada"]) return 7;
            [delegate showBuilderCode:nil];
            if (![delegate.builderCodeView.string containsString:@"import ui"] || ![delegate.builderCodeStatus.stringValue hasPrefix:@"Line 1 / "] || ![delegate.editor.string containsString:@"ui_button"]) return 69;
            NSRange windowLine = [delegate.builderCodeView.string rangeOfString:@"window "];
            [delegate.builderCodeView setSelectedRange:NSMakeRange(windowLine.location, 0)];
            [delegate textViewDidChangeSelection:[NSNotification notificationWithName:NSTextViewDidChangeSelectionNotification object:delegate.builderCodeView]];
            if (![delegate.builderCodeStatus.stringValue hasPrefix:@"Line 2 / "]) return 70;
            NSString *bindingSource = @"text username \"guest\"\nimport ui\nwindow \"Binding\" 320 180\nui_input \"Name\" 10 10 120 30\nui_id \"name_input\"\nui_label \"Guest\" 10 60 160 30\nui_id \"name_label\"\nui_bind \"name_input\" username\nui_bind \"name_label\" username";
            NSMutableArray *bindingUI = [NSMutableArray array];
            NSData *bindingCode = [VKEngine compile:bindingSource error:&error];
            if (!bindingCode || ![VKEngine run:bindingCode ui:bindingUI error:&error]) return 71;
            [delegate showUI:bindingUI];
            VKBoundInputField *boundInput = (VKBoundInputField *)delegate.previewWindows.lastObject.contentView.subviews[0];
            NSTextField *boundLabel = delegate.previewWindows.lastObject.contentView.subviews[1];
            boundInput.stringValue = @"Ada";
            [delegate controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:boundInput]];
            if (![boundLabel.stringValue isEqualToString:@"Ada"] || ![boundInput.boundValues[@"username"] isEqualToString:@"Ada"]) return 72;
            NSString *sceneSource = @"import ui\nwindow \"Scene\" 640 480\nui_scene3d 20 20 600 440\nui_camera3d 0 0 12\nui_light3d 4 6 8 900\nui_box3d 0 0 0 2 2 2 \"#FF5533\"\nui_id \"hero\"\nui_spin3d \"hero\" 3\nui_keymove3d \"hero\" \"w\" 1 0 0\nui_sphere3d 3 0 0 1 \"#33AAFF\"";
            NSMutableArray *sceneUI = [NSMutableArray array];
            NSData *sceneCode = [VKEngine compile:sceneSource error:&error];
            if (!sceneCode || ![VKEngine run:sceneCode ui:sceneUI error:&error]) return 73;
            [delegate showUI:sceneUI];
            VK3DView *renderView = nil;
            for (NSView *subview in delegate.previewWindows.lastObject.contentView.subviews) if ([subview isKindOfClass:VK3DView.class]) renderView = (VK3DView *)subview;
            VK3DObject *hero = renderView.objectsByID[@"hero"];
            if (!renderView || !renderView.allowsCameraControl || renderView.objects.count != 2 || !hero || hero.triangles.count != 12 || hero.spinPeriod != 3 || renderView.lights.count != 2) return 74;
            VKProgramWindow *renderWindow = (VKProgramWindow *)delegate.previewWindows.lastObject;
            renderWindow.focusedKeyHandler(@"w");
            if (hero.position.x != 1) return 116;
            hero.position = VKVectorMake(0, 0, 0);
            for (NSInteger mode = 0; mode < 2; mode++) {
                renderView.rendererMode.selectedSegment = mode;
                [renderView changeRendererMode:nil];
                [renderView displayIfNeeded];
                NSBitmapImageRep *renderedFrame = [renderView bitmapImageRepForCachingDisplayInRect:renderView.bounds];
                if (!renderedFrame) return 76;
                [renderView cacheDisplayInRect:renderView.bounds toBitmapImageRep:renderedFrame];
                BOOL hasLitPixel = NO;
                for (NSInteger y = renderedFrame.pixelsHigh / 4; y < renderedFrame.pixelsHigh * 3 / 4 && !hasLitPixel; y += 4) for (NSInteger x = renderedFrame.pixelsWide / 4; x < renderedFrame.pixelsWide * 3 / 4; x += 4) {
                    NSColor *pixel = [renderedFrame colorAtX:x y:y];
                    NSColor *rgb = [pixel colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    if (rgb && (rgb.redComponent > 0.15 || rgb.greenComponent > 0.15 || rgb.blueComponent > 0.15)) { hasLitPixel = YES; break; }
                }
                if (!hasLitPixel) return 77;
            }
            NSString *voxelSource = @"import ui\nwindow \"Voxel\" 320 240\nui_scene3d 0 0 320 240\nui_camera3d 0 0 4\nui_voxel3d 0 0 0 \"#55AA55\"\nui_voxel_controls3d 0.5 \"#AA8855\"\nui_box3d 3 0 0 1 1 1 \"#FF0000\"\nui_id \"mob\"\nui_frame3d\nui_remove3d \"mob\"\nui_end_frame3d";
            NSMutableArray *voxelUI = [NSMutableArray array];
            NSData *voxelCode = [VKEngine compile:voxelSource error:&error];
            if (!voxelCode || ![VKEngine run:voxelCode ui:voxelUI error:&error]) { NSLog(@"Voxel source: %@", error); return 117; }
            [delegate showUI:voxelUI];
            VKProgramWindow *voxelWindow = (VKProgramWindow *)delegate.previewWindows.lastObject;
            VK3DView *voxelView = nil;
            for (NSView *subview in voxelWindow.contentView.subviews) if ([subview isKindOfClass:VK3DView.class]) voxelView = (VK3DView *)subview;
            if (!voxelView || voxelView.voxelObjects.count != 1 || !voxelView.objectsByID[@"mob"]) return 118;
            VKVector3 cameraBeforeMove = [voxelView cameraPosition];
            voxelWindow.focusedRepeatKeyHandler(@"w");
            if (fabs([voxelView cameraPosition].z - (cameraBeforeMove.z - 0.5)) > 1e-6) return 119;
            NSPoint center = NSMakePoint(NSMidX(voxelView.bounds), NSMidY(voxelView.bounds));
            NSPoint windowCenter = [voxelView convertPoint:center toView:nil];
            NSEvent *rightClick = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:windowCenter modifierFlags:0 timestamp:0 windowNumber:voxelWindow.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
            [voxelView rightMouseDown:rightClick];
            if (voxelView.voxelObjects.count != 2 || !voxelView.voxelObjects[@"0,0,1"]) return 120;
            NSEvent *leftDown = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:windowCenter modifierFlags:0 timestamp:0 windowNumber:voxelWindow.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
            NSEvent *leftUp = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:windowCenter modifierFlags:0 timestamp:0 windowNumber:voxelWindow.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
            [voxelView mouseDown:leftDown]; [voxelView mouseUp:leftUp];
            if (voxelView.voxelObjects.count != 1 || voxelView.voxelObjects[@"0,0,1"]) return 121;
            [voxelView mouseDown:leftDown]; [voxelView mouseUp:leftUp];
            if (voxelView.voxelObjects.count != 0) return 122;
            [voxelView stepFrame];
            if (voxelView.objectsByID[@"mob"]) return 123;
            NSString *voxelSnapshot = NSProcessInfo.processInfo.environment[@"VEKTKOVE_TEST_VOXEL_SNAPSHOT"];
            if (voxelSnapshot.length) {
                NSString *example = [NSString stringWithContentsOfFile:@"examples/voxel3d.vk" encoding:NSUTF8StringEncoding error:nil];
                NSData *exampleCode = example ? [VKEngine compile:example error:&error] : nil;
                NSMutableArray *exampleUI = [NSMutableArray array];
                if (!exampleCode || ![VKEngine run:exampleCode ui:exampleUI error:&error]) return 124;
                [delegate showUI:exampleUI];
                VK3DView *exampleView = nil;
                for (NSView *subview in delegate.previewWindows.lastObject.contentView.subviews) if ([subview isKindOfClass:VK3DView.class]) exampleView = (VK3DView *)subview;
                if (!exampleView) return 125;
                [exampleView displayIfNeeded];
                NSBitmapImageRep *bitmap = [exampleView bitmapImageRepForCachingDisplayInRect:exampleView.bounds];
                if (!bitmap) return 126;
                [exampleView cacheDisplayInRect:exampleView.bounds toBitmapImageRep:bitmap];
                if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:voxelSnapshot atomically:YES]) return 127;
            }
            NSMutableArray *actions = [NSMutableArray array];
            NSData *actionCode = [VKEngine compile:@"import ui\nwindow \"Actions\" 400 300\nui_keyboard \"guitar\" 60\nui_shortcut \"F1\" \"Help\"\nui_label \"Spin\" 10 10 100 30\nauto_turn 2" error:&error];
            if (!actionCode || ![VKEngine run:actionCode ui:actions error:&error]) return 60;
            [delegate showUI:actions];
            VKProgramWindow *actionWindow = (VKProgramWindow *)delegate.previewWindows.lastObject;
            if (![actionWindow.registeredKeys containsObject:@"f1"] || ![actionWindow.registeredKeys containsObject:@"a"] || actionWindow.registeredKeys.count != 18) return 61;
            if (![actionWindow.contentView.subviews.firstObject.layer animationForKey:@"vektkove.auto_turn"]) return 62;
            VKTestProgramWindow *testWindow = [[VKTestProgramWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            __block NSString *pressedKey = nil;
            testWindow.focusedKeyHandler = ^(NSString *key) { pressedKey = key; };
            NSEvent *functionEvent = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:testWindow.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:kVK_F1];
            testWindow.testFocus = YES;
            [testWindow sendEvent:functionEvent];
            if (![pressedKey isEqualToString:@"f1"]) return 63;
            pressedKey = nil;
            testWindow.testFocus = NO;
            [testWindow sendEvent:functionEvent];
            if (pressedKey) return 65;
            [delegate.builderSoundPaths addObject:@"/tmp/vektkove-test-audio.wav"];
            NSMutableArray *soundUI = [NSMutableArray array];
            NSData *soundCode = [VKEngine compile:[delegate builderSource] error:&error];
            if (!soundCode || ![VKEngine run:soundCode ui:soundUI error:&error] || ![soundUI[1][1][0] isEqualToString:@"/tmp/vektkove-test-audio.wav"]) return 64;
            [delegate.builderSoundPaths removeAllObjects];
            if (![delegate.editor.string containsString:@"ui_button"]) return 4;
            NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"vk"]]];
            delegate.fileURL = temporary;
            if (![delegate saveSource:NO]) return 5;
            NSString *saved = [NSString stringWithContentsOfURL:temporary encoding:NSUTF8StringEncoding error:nil];
            delegate.editor.string = @"different";
            delegate.savedSource = delegate.editor.string;
            [delegate openSourceURL:temporary];
            if (![delegate.editor.string isEqualToString:saved]) return 8;
            [[NSFileManager defaultManager] removeItemAtURL:temporary error:nil];
            if (![saved isEqualToString:delegate.editor.string]) return 6;
            NSURL *project = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
            if (![[NSFileManager defaultManager] createDirectoryAtURL:project withIntermediateDirectories:NO attributes:nil error:nil]) return 12;
            [delegate setProjectFolder:project];
            project = delegate.projectURL;
            NSURL *folder = [delegate createProjectItem:@"src" parent:project folder:YES error:&error];
            NSURL *file = [delegate createProjectItem:@"main" parent:folder folder:NO error:&error];
            if (!folder || !file || ![file.pathExtension isEqualToString:@"vk"]) return 13;
            if ([delegate createProjectItem:@"src" parent:project folder:YES error:&error]) return 24;
            if (![@"out \"from project\"\n" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 14;
            if ([delegate createProjectItem:@"main.vk" parent:folder folder:NO error:&error]) return 15;
            if ([delegate createProjectItem:@"../outside" parent:project folder:NO error:&error]) return 16;
            [delegate refreshExplorer:nil];
            if ([delegate outlineView:delegate.explorer numberOfChildrenOfItem:nil] != 1) return 17;
            [delegate.explorer expandItem:delegate.projectItems[folder.path]];
            NSInteger projectRow = [delegate.explorer rowForItem:delegate.projectItems[file.path]];
            if (projectRow < 0) return 18;
            [delegate.explorer selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)projectRow] byExtendingSelection:NO];
            if (![delegate.editor.string isEqualToString:@"out \"from project\"\n"]) return 19;
            delegate.editor.string = @"set total 100\nadd total 23\nout $total";
            NSPipe *capture = [NSPipe pipe];
            NSError *taskError = nil;
            NSTask *task = [delegate startLauncherWithSource:delegate.editor.string arguments:@[@"--batch"] output:capture error:&taskError];
            if (!task) { fprintf(stderr, "Launcher handoff: %s\n", taskError.localizedDescription.UTF8String); return 20; }
            NSString *result = [[NSString alloc] initWithData:[capture.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
            [task waitUntilExit];
            if (task.terminationStatus != 0 || ![result isEqualToString:@"123\n"]) return 21;
            NSString *diskSource = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];
            if (![diskSource isEqualToString:@"out \"from project\"\n"]) return 25;
            capture = [NSPipe pipe];
            task = [delegate startLauncherWithSource:@"invalid" arguments:@[@"--batch"] output:capture error:&taskError];
            if (!task) return 22;
            result = [[NSString alloc] initWithData:[capture.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
            [task waitUntilExit];
            if (task.terminationStatus == 0 || ![result containsString:@"Compile error: Line 1:"]) return 23;
            [[NSFileManager defaultManager] removeItemAtURL:project error:nil];
            [delegate.elements removeAllObjects];
            for (NSUInteger index = 0; index < 200; index++) {
                [delegate.elements addObject:[@{@"type":@"label", @"text":@"Item", @"id":[NSString stringWithFormat:@"item%lu", (unsigned long)index], @"bind":@"", @"x":@"0", @"y":@"0", @"width":@"10", @"height":@"10", @"message":@"", @"color":@"#FFFFFF"} mutableCopy]];
            }
            [delegate.table reloadData];
            [delegate.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            [delegate duplicateElement:nil];
            if (delegate.elements.count != 201) return 106;
            NSPopUpButton *shapePicker = [[NSPopUpButton alloc] init];
            [shapePicker addItemsWithTitles:@[@"Choose", @"Box"]];
            [shapePicker selectItemAtIndex:1];
            [delegate add3DShape:shapePicker];
            if (delegate.elements.count != 202) return 107;
            NSData *largeBuilderCode = [VKEngine compile:[delegate builderSource] error:&error];
            NSMutableArray *largeBuilderUI = [NSMutableArray array];
            if (!largeBuilderCode || ![VKEngine run:largeBuilderCode ui:largeBuilderUI error:&error]) { NSLog(@"Large UI Maker design failed: %@", error); return 108; }
            printf("Native UI builder self-test passed\n");
            return 0;
        }
        [application run];
    }
    return 0;
}