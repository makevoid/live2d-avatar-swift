//
//  Live2DUserModel.m
//  Cubism
//
//  Created by Meng on 2025/8/30.
//

#import "Live2DModelSetting+Internal.h"
#import "Live2DModelSetting.h"
#import "Live2DUserModel+Internal.h"
#import "Live2DUserModel.h"
#import "Motion/Live2DCubismMotion+Internal.h"
#import "Motion/Live2DCubismMotion.h"
#import "Platform/PlatformConfig.h"
#import "Platform/PlatformError.h"
#import "Platform/PlatformOption.h"
#import <CubismDefaultParameterId.hpp>
#import <CubismModelSettingJson.hpp>
#import <Effect/CubismBreath.hpp>
#import <Effect/CubismEyeBlink.hpp>
#import <Effect/CubismPose.hpp>
#import <Id/CubismIdManager.hpp>
#import <Math/CubismMatrix44.hpp>
#import <Metal/Metal.h>
#import <Motion/CubismMotion.hpp>
#import <Motion/CubismMotionQueueEntry.hpp>
#import <Physics/CubismPhysics.hpp>
#import <Rendering/Metal/CubismRenderer_Metal.hpp>
#import <Rendering/Metal/CubismRenderingInstanceSingleton_Metal.h>
#import <Type/csmString.hpp>
#import <Utils/CubismString.hpp>
#include <cmath>

using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::DefaultParameterId;

@interface Live2DUserModel()

@property (nonatomic, readwrite) CGFloat opacity;
@property (nonatomic, readwrite) void *modelMatrix;

@property (nonatomic, assign) Live2D::Cubism::Live2DCubismUserModel *userModel;

/// 累计的时间差值[秒]
@property (nonatomic) CGFloat userTimeSeconds;

/// 眨眼参数
@property (nonatomic, assign) Csm::csmVector<Csm::CubismIdHandle> eyeBlinkIds;
/// 口型同步参数
@property (nonatomic, assign) Csm::csmVector<Csm::CubismIdHandle> lipSyncIds;

/// 碰撞区域
@property (nonatomic, assign) Csm::csmVector<Csm::csmRectF> hitArea;
/// 用户区域
@property (nonatomic, assign) Csm::csmVector<Csm::csmRectF> userArea;

/// 参数 ID
@property (nonatomic, assign) const Csm::CubismId *angleX;
@property (nonatomic, assign) const Csm::CubismId *angleY;
@property (nonatomic, assign) const Csm::CubismId *angleZ;
@property (nonatomic, assign) const Csm::CubismId *bodyAngleX;
@property (nonatomic, assign) const Csm::CubismId *eyeBallX;
@property (nonatomic, assign) const Csm::CubismId *eyeBallY;

/// 渲染缓冲区
@property (nonatomic, assign) Rendering::CubismOffscreenSurface_Metal renderBuffer;

/// 内部动作列表 (C++ map)
@property (nonatomic, assign) Csm::csmMap<Csm::csmString, Csm::ACubismMotion *> motions;
/// 内部表情列表 (C++ map)
@property (nonatomic, assign) Csm::csmMap<Csm::csmString, Csm::ACubismMotion *> expressions;

/// 拖拽位置 (内部使用)
@property (nonatomic) CGFloat internalDragX;
@property (nonatomic) CGFloat internalDragY;

/// 模型不透明度 (内部使用)
@property (nonatomic) CGFloat internalOpacity;

/// 已加载纹理
@property (nonatomic) NSMutableArray<Live2DTexture *> *textures;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *emotionValues;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *emotionOffsets;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *emotionMultipliers;

@end

@implementation Live2DUserModel

#pragma mark - Initialization

- (nullable instancetype)initWithHomeDir:(NSString *)homeDir error:(NSError **)error {
    self = [super init];
    if (self) {
        _userTimeSeconds = 0.0f;
        _internalDragX = 0.0f;
        _internalDragY = 0.0f;
        _internalOpacity = 1.0f;

        // 初始化参数ID
        _angleX = CubismFramework::GetIdManager()->GetId(ParamAngleX);
        _angleY = CubismFramework::GetIdManager()->GetId(ParamAngleY);
        _angleZ = CubismFramework::GetIdManager()->GetId(ParamAngleZ);
        _bodyAngleX = CubismFramework::GetIdManager()->GetId(ParamBodyAngleX);
        _eyeBallX = CubismFramework::GetIdManager()->GetId(ParamEyeBallX);
        _eyeBallY = CubismFramework::GetIdManager()->GetId(ParamEyeBallY);

        // 创建 UserModel 实例
        _userModel = new Live2D::Cubism::Live2DCubismUserModel();

        // 初始化设置
        _setting = [[Live2DModelSetting alloc] initWithHomeDir:homeDir error:error];
        if (!_setting || (error && *error)) {
            [self cleanup];
            return nil;
        }

        // 加载模型数据
        BOOL loadModelResult = [self loadModelWithError:error];
        if (!loadModelResult || (error && *error)) {
            return nil;
        }

        // 加载 render 和纹理
        BOOL loadTextureResult = [self reloadRenderAndTexturesWithError:error];
        if (!loadTextureResult || (error && *error)) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self cleanup];
}

- (void)cleanup {
    if (_userModel) {
        _userModel->GetMotionManager()->StopAllMotions();
        _userModel->GetExpressionManager()->StopAllMotions();
    }
    // 释放所有动作和表情
    [self releaseMotions];
    [self releaseExpressions];

    // 释放动作组
    for (csmInt32 i = 0; _setting && i < self.setting.modelSetting->GetMotionGroupCount(); i++) {
        const csmChar* group = self.setting.modelSetting->GetMotionGroupName(i);
        [self releaseMotionGroup:group];
    }

    // 释放纹理
    [_textures removeAllObjects];

    // 销毁渲染缓冲区
    _renderBuffer.DestroyOffscreenSurface();

    // 释放 UserModel
    if (_userModel) {
        delete _userModel;
        _userModel = nullptr;
    }
}

#pragma mark - Model Loading

/// 加载模型数据
- (BOOL)loadModelWithError:(NSError **)error {
    _userModel->SetInitialized(false);
    _userModel->SetUpdating(true);

    // 加载 Cubism 模型
    BOOL loadModelResult = [self loadCubismModelWithError:error];
    if (!loadModelResult || (error && *error)) {
        return NO;
    }

    // 加载动作和表情
    [self loadMotionsAndExpressions];
    // 加载物理和姿势文件
    [self loadPhyicsAndPose];
    // 加载用户数据
    [self loadUserData];

    // 加载眨眼和口型
    [self loadEyeBlinkAndLip];
    // 加载呼吸
    [self loadBreath];
    // 加载布局
    [self loadLayout];

    // 停止播放所有动作
    _userModel->GetMotionManager()->StopAllMotions();

    // 完成
    _userModel->SetUpdating(false);
    _userModel->SetInitialized(true);

    return YES;
}

/// 加载 Cubism 模型
- (BOOL)loadCubismModelWithError:(NSError **)error {
    csmByte* buffer;
    csmSizeInt size;

    csmString cPath = [_setting.modelFilePath cStringUsingEncoding:NSUTF8StringEncoding];
    buffer = PlatformOption::LoadFileAsBytes(cPath.GetRawString(), &size);
    if (!buffer || size <= 0) {
        if (error) *error = [PlatformError errorWithCode:CubismErrorCodeLoadCubismModelFailed];
        return NO;
    }
    _userModel->LoadModel(buffer, size, true);
    PlatformOption::ReleaseBytes(buffer);

    if (_userModel->GetMoc() == NULL || _userModel->GetModel() == NULL) {
        if (error) {
            *error = [PlatformError errorWithCode:CubismErrorCodeLoadCubismModelFailed];
        }
        return NO;
    }

    return YES;
}

/// 加载动作和表情
- (void)loadMotionsAndExpressions {
    csmByte* buffer;
    csmSizeInt size;

    // 加载动作
    for (csmInt32 i = 0; i < _setting.modelSetting->GetMotionGroupCount(); i++) {
        const csmChar* group = _setting.modelSetting->GetMotionGroupName(i);
        const csmInt32 motionCount = _setting.modelSetting->GetMotionCount(group);

        for (csmInt32 i = 0; i < motionCount; i++) {
            // 例如 idle_0
            csmString name = Utils::CubismString::GetFormatedString("%s_%d", group, i);
            csmString path = self.setting.modelSetting->GetMotionFileName(group, i);
            path = csmString(_setting.homeDir.UTF8String) + path;

            buffer = PlatformOption::LoadFileAsBytes(path.GetRawString(), &size);
            auto motion = _userModel->LoadMotion(buffer,
                                                 size,
                                                 name.GetRawString(),
                                                 NULL,
                                                 NULL,
                                                 _setting.modelSetting,
                                                 group,
                                                 i
                                                 );
            PlatformOption::ReleaseBytes(buffer);

            if (motion) {
                if (_motions[name] != NULL) {
                    ACubismMotion::Delete(_motions[name]);
                }
                _motions[name] = motion;
            }
        }
    }

    // 加载表情
    for (NSString *expressionName in _setting.expressionFilePaths.allKeys) {
        NSString *expressionFilePath = _setting.expressionFilePaths[expressionName];
        csmString cName = [expressionName cStringUsingEncoding:NSUTF8StringEncoding];
        csmString cPath = [expressionFilePath cStringUsingEncoding:NSUTF8StringEncoding];

        csmByte* buffer;
        csmSizeInt size;
        buffer = PlatformOption::LoadFileAsBytes(cPath.GetRawString(), &size);
        ACubismMotion* motion = _userModel->LoadExpression(buffer, size, cName.GetRawString());
        PlatformOption::ReleaseBytes(buffer);

        if (motion) {
            if (_expressions[cName] != NULL) {
                ACubismMotion::Delete(_expressions[cName]);
                _expressions[cName] = NULL;
            }
            _expressions[cName] = motion;
        }
    }
}

/// 加载物理和姿势文件
- (void)loadPhyicsAndPose {
    csmByte* buffer;
    csmSizeInt size;

    if (_setting.phyicsFilePath) {
        csmString cPath = [_setting.phyicsFilePath cStringUsingEncoding:NSUTF8StringEncoding];
        buffer = PlatformOption::LoadFileAsBytes(cPath.GetRawString(), &size);
        _userModel->LoadPhysics(buffer, size);
        PlatformOption::ReleaseBytes(buffer);
    }

    if (_setting.poseFilePath) {
        csmString cPath = [_setting.poseFilePath cStringUsingEncoding:NSUTF8StringEncoding];
        buffer = PlatformOption::LoadFileAsBytes(cPath.GetRawString(), &size);
        _userModel->LoadPose(buffer, size);
        PlatformOption::ReleaseBytes(buffer);
    }
}

/// 加载用户数据
- (void)loadUserData {
    if (!_setting.userDataFilePath) {
        return;
    }

    csmByte* buffer;
    csmSizeInt size;
    csmString cPath = [_setting.userDataFilePath cStringUsingEncoding:NSUTF8StringEncoding];
    buffer = PlatformOption::LoadFileAsBytes(cPath.GetRawString(), &size);
    _userModel->LoadUserData(buffer, size);
    PlatformOption::ReleaseBytes(buffer);
}

/// 加载眨眼数据和口型
- (void)loadEyeBlinkAndLip {
    // 设置眨眼
    if (_setting.modelSetting->GetEyeBlinkParameterCount() > 0) {
        _userModel->SetEyeBlink(CubismEyeBlink::Create(_setting.modelSetting));
    }

    // EyeBlinkIds 眨眼 id
    {
        csmInt32 eyeBlinkIdCount = _setting.modelSetting->GetEyeBlinkParameterCount();
        for (csmInt32 i = 0; i < eyeBlinkIdCount; ++i) {
            _eyeBlinkIds.PushBack(_setting.modelSetting->GetEyeBlinkParameterId(i));
        }
    }

    // LipSyncIds 口型同步
    {
        csmInt32 lipSyncIdCount = _setting.modelSetting->GetLipSyncParameterCount();
        for (csmInt32 i = 0; i < lipSyncIdCount; ++i) {
            _lipSyncIds.PushBack(_setting.modelSetting->GetLipSyncParameterId(i));
        }
    }

    // set motion effect
    for (auto it = _motions.Begin(); it != _motions.End(); ++it) {
        CubismMotion *motion = static_cast<CubismMotion *>(it->Second);
        motion->SetEffectIds(_eyeBlinkIds, _lipSyncIds);
    }
}

/// 加载呼吸数据
- (void)loadBreath {
    _userModel->SetBreath(CubismBreath::Create());

    csmVector<CubismBreath::BreathParameterData> breathParameters;
    const CubismId *breathId = CubismFramework::GetIdManager()->GetId(ParamBreath);
    breathParameters.PushBack(CubismBreath::BreathParameterData(_angleX, 0.0f, 15.0f, 6.5345f, 0.5f));
    breathParameters.PushBack(CubismBreath::BreathParameterData(_angleY, 0.0f, 8.0f, 3.5345f, 0.5f));
    breathParameters.PushBack(CubismBreath::BreathParameterData(_angleZ, 0.0f, 10.0f, 5.5345f, 0.5f));
    breathParameters.PushBack(CubismBreath::BreathParameterData(_bodyAngleX, 0.0f, 4.0f, 15.5345f, 0.5f));
    breathParameters.PushBack(CubismBreath::BreathParameterData(breathId, 0.5f, 0.5f, 3.2345f, 0.5f));
    _userModel->GetBreath()->SetParameters(breathParameters);
}

/// 加载布局
- (void)loadLayout {
    csmMap<csmString, csmFloat32> layout;
    _setting.modelSetting->GetLayoutMap(layout);
    _userModel->GetModelMatrix()->SetupFromLayout(layout);
    _userModel->GetModel()->SaveParameters();
}

/// 重新加载 render 和纹理
- (BOOL)reloadRenderAndTexturesWithError:(NSError **)error {
    // 重新创建渲染器
    _userModel->CreateRenderer();
    auto renderer = _userModel->GetRenderer<Rendering::CubismRenderer_Metal>();

    NSMutableArray<Live2DTexture *> *textures = [NSMutableArray array];
    for (csmUint32 index = 0; index < _setting.textureFilePaths.count; index++) {
        NSString *textureFilePath = _setting.textureFilePaths[index];
        Live2DTexture *texture = [[Live2DTexture alloc] initWithTextureFilePath:textureFilePath error:error];
        if (!texture) {
            return NO;
        }

        [textures addObject:texture];
        renderer->BindTexture(index, texture.texture);
    }
    _textures = textures;

    // 无纹理加载成功
    if (_textures.count <= 0) {
        if (error) {
            *error = [PlatformError errorWithCode:CubismErrorCodeLoadTextureFailed];
            return NO;
        }
    }

    // 设置预乘 alpha
    renderer->IsPremultipliedAlpha(true);

    return YES;
}

#pragma mark - Motion Management

- (void)releaseMotionGroup:(const csmChar*)group {
    const csmInt32 count = self.setting.modelSetting->GetMotionCount(group);
    for (csmInt32 i = 0; i < count; i++) {
        csmString voice = self.setting.modelSetting->GetMotionSoundFileName(group, i);
        if (strcmp(voice.GetRawString(), "") != 0) {
            csmString path = voice;
            path = csmString(_setting.homeDir.UTF8String) + path;
            // TODO: 释放音频资源
        }
    }
}

- (void)releaseMotions {
    for (auto it = _motions.Begin(); it != _motions.End(); ++it) {
        ACubismMotion::Delete(it->Second);
    }
    _motions.Clear();
}

- (void)releaseExpressions {
    for (csmMap<csmString, ACubismMotion*>::const_iterator iter = _expressions.Begin(); iter != _expressions.End(); ++iter) {
        ACubismMotion::Delete(iter->Second);
    }
    _expressions.Clear();
}

#pragma mark - Public Interface

- (void)reloadRenderer {
    if (!_userModel) {
        return;
    }

    [self reloadRenderAndTexturesWithError:nil];
}

- (void)update {
    [self updateWithDeltaTime:1.0 / 60.0];
}

- (void)updateWithDeltaTime:(double)seconds {
    if (!_userModel) {
        assert(false);
        return;
    }

    CubismModel *model = _userModel->GetModel();
    CubismMotionManager *motionManager = _userModel->GetMotionManager();

    const csmFloat32 deltaTimeSeconds = fmax(0.0, fmin(seconds, 0.1));
    _userTimeSeconds += deltaTimeSeconds;

    _userModel->SetDragging(_internalDragX, _internalDragY);
    _userModel->GetDragManager()->Update(deltaTimeSeconds);
    const float dragX = _userModel->GetDragManager()->GetX();
    const float dragY = _userModel->GetDragManager()->GetY();

    // 通过动作更新参数的有无
    csmBool motionUpdated = false;

    //-----------------------------------------------------------------
    model->LoadParameters(); // 加载上次保存的状态
    if (motionManager->IsFinished()) {
        // 若没有动作播放，则从待机动作中随机播放一个
        [self startRandomMotionWithGroup:@"idle" priority:1 finishedHandler:nil beganHandler:nil];
    } else {
        motionUpdated = motionManager->UpdateMotion(model, deltaTimeSeconds); // 更新动作
    }
    model->SaveParameters(); // 保存状态
    //-----------------------------------------------------------------

    // 不透明度
    _internalOpacity = model->GetModelOpacity();

    // 眨眼
    if (!motionUpdated) {
        if (_userModel->GetEyeBlink() != NULL) {
            // 主动作未更新时
            _userModel->GetEyeBlink()->UpdateParameters(model, deltaTimeSeconds); // 眨眼
        }
    }

    if (_userModel->GetExpressionManager() != NULL) {
        _userModel->GetExpressionManager()->UpdateMotion(model, deltaTimeSeconds); // 通过表情更新参数（相对变化）
    }

    // 拖拽变化
    // 通过拖拽调整脸部朝向
    model->AddParameterValue(_angleX, dragX * 30); // 添加-30到30的值
    model->AddParameterValue(_angleY, dragY * 30);
    model->AddParameterValue(_angleZ, dragX * dragY * -30);

    // 通过拖拽调整身体朝向
    model->AddParameterValue(_bodyAngleX, dragX * 10); // 添加-10到10的值

    // 通过拖拽调整眼睛朝向
    model->AddParameterValue(_eyeBallX, dragX); // 添加-1到1的值
    model->AddParameterValue(_eyeBallY, dragY);

    // 呼吸计算
    if (_userModel->GetBreath() != NULL) {
        _userModel->GetBreath()->UpdateParameters(model, deltaTimeSeconds);
    }

    model->SetParameterValue(CubismFramework::GetIdManager()->GetId(ParamMouthOpenY), _mouthOpen);

    // Transient emotion layer: no SaveParameters here, so gestures never accumulate
    // or corrupt accessory motions. Eye multipliers preserve automatic blinking.
    for (NSInteger mode = 0; mode < 3; ++mode) {
        NSDictionary<NSString *, NSNumber *> *parameters = mode == 0 ? _emotionValues :
            (mode == 1 ? _emotionOffsets : _emotionMultipliers);
        for (NSString *identifier in parameters) {
            const auto index = model->GetParameterIndex(CubismFramework::GetIdManager()->GetId(identifier.UTF8String));
            if (index < 0 || index >= model->GetParameterCount()) continue;
            const double value = parameters[identifier].doubleValue;
            if (!std::isfinite(value)) continue;
            if (mode == 0) model->SetParameterValue(index, value);
            else if (mode == 1) model->AddParameterValue(index, value);
            else model->SetParameterValue(index, model->GetParameterValue(index) * value);
        }
    }

    // 物理计算
    if (_userModel->GetPhysics() != NULL) {
        _userModel->GetPhysics()->Evaluate(model, deltaTimeSeconds);
    }

    // 唇形同步
    if (_userModel->GetLipSync()) {
        csmFloat32 value = 0;
        // 这里应该实现从系统获取音量的逻辑，例如：
        // AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        // value = audioSession.outputVolume;
        for (csmUint32 i = 0; i < _lipSyncIds.GetSize(); ++i) {
            model->AddParameterValue(_lipSyncIds[i], value, 0.8f);
        }
    }

    // 姿势设置
    if (_userModel->GetPose() != NULL) {
        _userModel->GetPose()->UpdateParameters(model, deltaTimeSeconds);
    }

    model->Update();
}

- (NSInteger)parameterCount { return _userModel->GetModel()->GetParameterCount(); }
- (NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *)parameterRanges {
    auto model = _userModel->GetModel();
    NSMutableDictionary *ranges = [NSMutableDictionary dictionary];
    for (int index = 0; index < model->GetParameterCount(); ++index) {
        NSString *identifier = @(model->GetParameterId(index)->GetString().GetRawString());
        ranges[identifier] = @{@"min": @(model->GetParameterMinimumValue(index)),
                              @"max": @(model->GetParameterMaximumValue(index)),
                              @"default": @(model->GetParameterDefaultValue(index))};
    }
    return ranges;
}
- (void)setEmotionValues:(NSDictionary<NSString *, NSNumber *> *)values
                 offsets:(NSDictionary<NSString *, NSNumber *> *)offsets
             multipliers:(NSDictionary<NSString *, NSNumber *> *)multipliers {
    _emotionValues = [values copy];
    _emotionOffsets = [offsets copy];
    _emotionMultipliers = [multipliers copy];
}
- (NSInteger)drawableCount { return _userModel->GetModel()->GetDrawableCount(); }
- (BOOL)setDrawable:(NSString *)identifier hidden:(BOOL)hidden {
    const auto id = CubismFramework::GetIdManager()->GetId(identifier.UTF8String);
    const auto index = _userModel->GetModel()->GetDrawableIndex(id);
    if (index < 0) return NO;
    _userModel->GetRenderer<Rendering::CubismRenderer_Metal>()->SetDrawableHidden(index, hidden);
    return YES;
}
- (double)parameterValueForID:(NSString *)identifier {
    return _userModel->GetModel()->GetParameterValue(CubismFramework::GetIdManager()->GetId(identifier.UTF8String));
}
- (BOOL)setParameter:(NSString *)identifier value:(double)value {
    auto model = _userModel->GetModel();
    const auto index = model->GetParameterIndex(CubismFramework::GetIdManager()->GetId(identifier.UTF8String));
    if (index < 0 || index >= model->GetParameterCount()) return NO;
    model->SetParameterValue(index, value);
    model->SaveParameters();
    return YES;
}
- (void)resetPose {
    _userModel->GetMotionManager()->StopAllMotions();
    _userModel->GetExpressionManager()->StopAllMotions();
    auto model = _userModel->GetModel();
    for (int i = 0; i < model->GetParameterCount(); ++i) {
        model->SetParameterValue(i, model->GetParameterDefaultValue(i));
    }
    model->SaveParameters();
    _internalDragX = _internalDragY = _mouthOpen = 0;
}
- (void)renderWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                passDescriptor:(MTLRenderPassDescriptor *)descriptor
                         width:(double)width height:(double)height zoom:(double)zoom
                          panX:(double)panX panY:(double)panY {
    if (!_userModel || width <= 0 || height <= 0) return;
    Rendering::CubismRenderer_Metal::StartFrame(PlatformConfig.MTLDevice, commandBuffer, descriptor);
    CubismMatrix44 projection;
    const float aspect = (float)(height / width);
    projection.Scale(aspect * zoom, zoom);
    projection.Translate(panX, panY);
    [self drawWithMatrix:projection.GetArray()];
}

- (void)drawWithMatrix:(float[16])matrix {
    if (_userModel == nullptr) {
        return;
    }

    CubismMatrix44 cubismMatrix;
    cubismMatrix.SetMatrix(matrix);

    // 乘以模型矩阵，将模型变换应用到视图投影矩阵
    cubismMatrix.MultiplyByMatrix(_userModel->GetModelMatrix());

    auto renderer = _userModel->GetRenderer<Rendering::CubismRenderer_Metal>();
    if (renderer) {
        renderer->SetMvpMatrix(&cubismMatrix);
        renderer->DrawModel();
    }
}

- (NSInteger)startMotionWithGroup:(NSString *)group
                            index:(NSInteger)index
                         priority:(NSInteger)priority
                  finishedHandler:(Live2DCubismMotionFinishedCallback)finishedHandler
                     beganHandler:(Live2DCubismMotionBeganCallback)beganHandler {
    if (_userModel == nullptr) {
        return -1;
    }

    if (index < 0 || index >= _setting.modelSetting->GetMotionCount(group.UTF8String)) return -1;

    if (priority == 3) {
        _userModel->GetMotionManager()->SetReservePriority((csmInt32)priority);
    } else if (!_userModel->GetMotionManager()->ReserveMotion((csmInt32)priority)) {
        return -1;
    }

    const csmString fileName = _setting.modelSetting->GetMotionFileName([group cStringUsingEncoding:NSUTF8StringEncoding], (csmInt32)index);

    // 例如 idle_0
    csmString name = Utils::CubismString::GetFormatedString("%s_%d", [group cStringUsingEncoding:NSUTF8StringEncoding], (csmInt32)index);
    CubismMotion* motion = static_cast<CubismMotion*>(_motions[name.GetRawString()]);
    csmBool autoDelete = false;

    if (motion == NULL) {
        csmString path = fileName;
        path = csmString(_setting.homeDir.UTF8String) + path;

        csmByte* buffer;
        csmSizeInt size;
        buffer = PlatformOption::LoadFileAsBytes(path.GetRawString(), &size);
        motion = static_cast<CubismMotion*>(_userModel->LoadMotion(buffer, size, NULL, NULL, NULL, self.setting.modelSetting, [group cStringUsingEncoding:NSUTF8StringEncoding], (csmInt32)index));

        if (motion) {
            motion->SetEffectIds(_eyeBlinkIds, _lipSyncIds);
            autoDelete = true; // 終了時にメモリから削除
        }

        PlatformOption::ReleaseBytes(buffer);
    } else {
        // 设置回调
        if (beganHandler) {
            // TODO: 设置 began 回调
        }
        if (finishedHandler) {
            // TODO: 设置 finished 回调
        }
    }

    // TODO: 处理声音文件

    if (!motion) return -1;
    return (NSInteger)_userModel->GetMotionManager()->StartMotionPriority(motion, autoDelete, (csmInt32)priority);
}

- (NSInteger)startRandomMotionWithGroup:(NSString *)group
                               priority:(NSInteger)priority
                        finishedHandler:(Live2DCubismMotionFinishedCallback)finishedHandler
                           beganHandler:(Live2DCubismMotionBeganCallback)beganHandler {
    if (_setting.modelSetting->GetMotionCount([group cStringUsingEncoding:NSUTF8StringEncoding]) == 0) {
        return -1;
    }

    csmInt32 no = rand() % self.setting.modelSetting->GetMotionCount([group cStringUsingEncoding:NSUTF8StringEncoding]);

    return [self startMotionWithGroup:group index:no priority:priority finishedHandler:finishedHandler beganHandler:beganHandler];
}

- (void)setExpression:(NSString *)expressionID {
    ACubismMotion* motion = _expressions[[expressionID cStringUsingEncoding:NSUTF8StringEncoding]];
    if (motion != NULL) {
        _userModel->GetExpressionManager()->StartMotion(motion, false);
    }
}

- (void)setRandomExpression {
    if (_expressions.GetSize() == 0) {
        return;
    }

    csmInt32 no = rand() % _expressions.GetSize();
    csmMap<csmString, ACubismMotion*>::const_iterator map_ite;
    csmInt32 i = 0;
    for (map_ite = _expressions.Begin(); map_ite != _expressions.End(); map_ite++) {
        if (i == no) {
            csmString name = (*map_ite).First;
            [self setExpression:[NSString stringWithUTF8String:name.GetRawString()]];
            return;
        }
        i++;
    }
}

- (BOOL)hitTestWithHitAreaName:(NSString *)hitAreaName x:(CGFloat)x y:(CGFloat)y {
    // 若透明则无判定
    if (_internalOpacity < 1) {
        return false;
    }
    const csmInt32 count = _setting.modelSetting->GetHitAreasCount();
    for (csmInt32 i = 0; i < count; i++) {
        if (strcmp(_setting.modelSetting->GetHitAreaName(i), [hitAreaName cStringUsingEncoding:NSUTF8StringEncoding]) == 0) {
            const CubismIdHandle drawID = self.setting.modelSetting->GetHitAreaId(i);
            return _userModel->IsHit(drawID, (csmFloat32)x, (csmFloat32)y);
        }
    }
    return false; // 若不存在则返回false
}

- (BOOL)hasMocConsistencyFromFile:(NSString *)mocFileName {
    csmString path = [mocFileName cStringUsingEncoding:NSUTF8StringEncoding];
    path = csmString(_setting.homeDir.UTF8String) + path;

    csmByte* buffer;
    csmSizeInt size;

    buffer = PlatformOption::LoadFileAsBytes(path.GetRawString(), &size);

    csmBool consistency = CubismMoc::HasMocConsistencyFromUnrevivedMoc(buffer, size);

    PlatformOption::ReleaseBytes(buffer);

    return consistency ? YES : NO;
}

- (void)motionEventFired:(NSString *)eventValue {
    CubismLogInfo("%s is fired on Live2DUserModel!!", [eventValue cStringUsingEncoding:NSUTF8StringEncoding]);
}

#pragma mark - Property Accessors

- (CGFloat)opacity {
    return _internalOpacity;
}

- (void)setDragX:(CGFloat)dragX {
    _internalDragX = dragX;
}

- (void)setDragY:(CGFloat)dragY {
    _internalDragY = dragY;
}

- (CGFloat)dragX {
    return _internalDragX;
}

- (CGFloat)dragY {
    return _internalDragY;
}

- (void *)modelMatrix {
    return _userModel ? _userModel->GetModelMatrix() : nullptr;
}

@end
