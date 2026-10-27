//
//  Live2DCubism.h
//  Cubism
//
//  Created by Meng on 2025/8/26.
//

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface Live2DCubism : NSObject

+ (Live2DCubism *)shared;

/// 启动 SDK
- (void)start;
- (void)setShaderLibrary:(id<MTLLibrary>)library;
/// 停止 SDK
- (void)stop;

@end

NS_ASSUME_NONNULL_END
