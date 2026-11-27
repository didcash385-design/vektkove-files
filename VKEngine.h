#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, VKOpcode) {
	VKText = 1, VKSet, VKAdd, VKSubtract, VKMultiply, VKDivide, VKModulo, VKPower,
	VKConcat, VKUpper, VKLower, VKLength, VKEqual, VKNotEqual, VKLess, VKLessEqual,
	VKGreater, VKGreaterEqual, VKNot, VKAnd, VKOr, VKNegate, VKAbs, VKRound,
	VKFloor, VKCeil, VKSqrt, VKOut, VKHalt, VKLabel, VKJump, VKIf, VKUnless,
	VKWindow, VKUILabel, VKUIButton, VKUIInput,
	VKMin, VKMax, VKSin, VKCos, VKTan, VKAsin, VKAcos, VKAtan, VKLog, VKLog10,
	VKExp, VKSign, VKTruncate, VKIsNumber, VKIsText, VKEmpty, VKTrim, VKContains,
	VKStartsWith, VKEndsWith, VKReplace, VKUIColor, VKUIShortcut, VKUINote, VKUIKeynote, VKUISound,
	VKUIKeyboard, VKUIAutoTurn, VKImport, VKUIID, VKUIBind,
	VKUIScene3D, VKUICamera3D, VKUILight3D, VKUIBox3D, VKUISphere3D,
	VKUICylinder3D, VKUICone3D, VKUITorus3D, VKUIPlane3D, VKUISpin3D,
	VKTerminalRun, VKTerminalEcho, VKTerminalKeywords, VKCite,
	VKUIScene2D, VKUIRect2D, VKUICircle2D, VKUIVelocity2D, VKUIKeyMove2D,
	VKServerScript, VKLocalScript, VKNetListen, VKNetConnect, VKNetSend, VKNetReceive, VKNetClose,
	VKNetListenMulti, VKNetSendTo, VKNetReceiveFrom, VKNetBroadcast,
	VKUIPhysics2D, VKUIGravity2D, VKUIFrame2D, VKUIEndFrame2D, VKUIMove2D, VKUIForce2D,
	VKUISetVelocity2D, VKUIFrameData,
	VKUIPhysics3D, VKUIGravity3D, VKUIFrame3D, VKUIEndFrame3D, VKUIMove3D, VKUIForce3D, VKUISetVelocity3D, VKUIVelocity3D,
VKUIMesh3D,
		VKEncode, VKDecode, VKCodecList,
		VKAIConfigure, VKTrain, VKAIClear, VKAIAsk
};

@interface VKEngine : NSObject
+ (NSData *)compile:(NSString *)source error:(NSString **)error;
+ (NSArray<NSString *> *)diagnose:(NSString *)source;
+ (NSString *)run:(NSData *)bytecode error:(NSString **)error;
+ (NSString *)run:(NSData *)bytecode ui:(NSMutableArray *)ui error:(NSString **)error;
+ (NSArray<NSString *> *)keywords;
+ (NSUInteger)keywordCount;
+ (NSUInteger)baseKeywordCount;
+ (NSString *)keywordAtIndex:(NSUInteger)index;
+ (NSString *)helpForKeyword:(NSString *)keyword;
+ (NSString *)categoryForKeyword:(NSString *)keyword;
+ (NSInteger)dimensionForKeyword:(NSString *)keyword;
+ (NSArray *)runFrameCallback:(NSArray *)instructions variables:(NSMutableDictionary *)variables error:(NSString **)error;
@end