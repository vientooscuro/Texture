//
//  ASEditableTextNodeTests.mm
//  Texture
//
//  Copyright (c) Facebook, Inc. and its affiliates.  All rights reserved.
//  Changes after 4/13/2017 are: Copyright (c) Pinterest, Inc.  All rights reserved.
//  Licensed under Apache 2.0: http://www.apache.org/licenses/LICENSE-2.0
//

#import <XCTest/XCTest.h>
#import <AsyncDisplayKit/ASLayout.h>
#import <AsyncDisplayKit/ASDisplayNode+Subclasses.h>
#import <AsyncDisplayKit/ASEditableTextNode.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL CGSizeEqualToSizeWithIn(CGSize size1, CGSize size2, CGFloat delta)
{
  return fabs(size1.width - size2.width) < delta && fabs(size1.height - size2.height) < delta;
}

@interface ASMeasurementLinesDeinitProbe : NSObject
@property (nonatomic, copy) dispatch_block_t onDealloc;
@end

@implementation ASMeasurementLinesDeinitProbe
- (void)dealloc
{
  if (_onDealloc) { _onDealloc(); }
}
@end

@interface ASLineLimitBlockedLayoutNode : ASEditableTextNode
@property (nonatomic, strong) dispatch_semaphore_t measurementEntered;
@property (nonatomic, strong) dispatch_semaphore_t continueMeasurement;
@end

@implementation ASLineLimitBlockedLayoutNode
- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize
{
  dispatch_semaphore_signal(self.measurementEntered);
  dispatch_semaphore_wait(self.continueMeasurement, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  return [super calculateSizeThatFits:constrainedSize];
}
@end

@interface ASInitiallyNonScrollingTextNode : ASEditableTextNode
@end

@implementation ASInitiallyNonScrollingTextNode
- (instancetype)init
{
  return [super initWithInitialScrollEnabled:NO];
}
@end

@interface ASInsetSetterGate : NSObject
@property (nonatomic, strong) dispatch_semaphore_t entered;
@property (nonatomic, strong) dispatch_semaphore_t readFinished;
@property (nonatomic) long waitResult;
@end

@implementation ASInsetSetterGate
@end

static char ASInsetSetterGateKey;

static void ASBlockingTextViewInsetSetter(UITextView *view, SEL selector, UIEdgeInsets inset)
{
  ASInsetSetterGate *gate = objc_getAssociatedObject(view, &ASInsetSetterGateKey);
  dispatch_semaphore_signal(gate.entered);
  gate.waitResult = dispatch_semaphore_wait(gate.readFinished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  struct objc_super superInfo = { view, class_getSuperclass(object_getClass(view)) };
  ((void (*)(struct objc_super *, SEL, UIEdgeInsets))objc_msgSendSuper)(&superInfo, selector, inset);
}

@interface ASEditableTextNodeTests : XCTestCase
@property (nonatomic) ASEditableTextNode *editableTextNode;
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

@implementation ASEditableTextNodeTests

- (void)setUp
{
  [super setUp];
  
  _editableTextNode = [[ASEditableTextNode alloc] init];
  
  NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:@"Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."];
  NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
  para.alignment = NSTextAlignmentCenter;
  para.lineSpacing = 1.0;
  [mas addAttribute:NSParagraphStyleAttributeName value:para
              range:NSMakeRange(0, mas.length - 1)];
  
  // Vary the linespacing on the last line
  NSMutableParagraphStyle *lastLinePara = [NSMutableParagraphStyle new];
  lastLinePara.alignment = para.alignment;
  lastLinePara.lineSpacing = 5.0;
  [mas addAttribute:NSParagraphStyleAttributeName value:lastLinePara
              range:NSMakeRange(mas.length - 1, 1)];
  
  _attributedText = mas;
  _editableTextNode.attributedText = _attributedText;
}

#pragma mark - ASEditableTextNode

- (void)testAllocASEditableTextNode
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  XCTAssertTrue([[node class] isSubclassOfClass:[ASEditableTextNode class]], @"ASEditableTextNode alloc should return an instance of ASEditableTextNode, instead returned %@", [node class]);
}

- (void)testInsetSnapshotDetectsRepeatedAndABAWrites
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  UIEdgeInsets initial = UIEdgeInsetsMake(1, 2, 3, 4);
  node.textContainerInset = initial;
  ASEditableTextInsetSnapshot first = node.textContainerInsetSnapshot;
  node.textContainerInset = UIEdgeInsetsMake(5, 6, 7, 8);
  node.textContainerInset = initial;
  ASEditableTextInsetSnapshot afterABA = node.textContainerInsetSnapshot;
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(first.inset, afterABA.inset));
  XCTAssertNotEqual(first.revision, afterABA.revision);
  node.textContainerInset = initial;
  XCTAssertNotEqual(afterABA.revision, node.textContainerInsetSnapshot.revision);
}

- (void)testInsetSnapshotMatchesLivePropertyBeforeAndAfterLoading
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  node.textContainerInset = UIEdgeInsetsMake(1, 2, 3, 4);
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(node.textContainerInsetSnapshot.inset, node.textContainerInset));
  UITextView *view = node.textView;
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(view.textContainerInset, node.textContainerInsetSnapshot.inset));
  node.textContainerInset = UIEdgeInsetsMake(5, 6, 7, 8);
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(view.textContainerInset, node.textContainerInsetSnapshot.inset));
}

- (void)testInsetSnapshotDuringColdConcurrentMeasurement
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  node.attributedText = self.attributedText;
  XCTestExpectation *writes = [self expectationWithDescription:@"inset writes completed"];
  XCTestExpectation *measurements = [self expectationWithDescription:@"measurements completed"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (NSUInteger index = 0; index < 200; ++index) {
      CGFloat value = index % 4;
      node.textContainerInset = UIEdgeInsetsMake(value, value, value, value);
      (void)node.textContainerInsetSnapshot;
    }
    [writes fulfill];
  });
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (NSUInteger index = 0; index < 200; ++index) {
      CGSize size = [node calculateSizeThatFits:CGSizeMake(120, CGFLOAT_MAX)];
      XCTAssertTrue(isfinite(size.width) && isfinite(size.height));
    }
    [measurements fulfill];
  });
  [self waitForExpectations:@[writes, measurements] timeout:10.0];
}

- (void)testInsetSnapshotWhileLoadedNodeChangesOnMain
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  UITextView *view = node.textView;
  Class originalClass = object_getClass(view);
  NSString *name = [@"ASInsetSetterTest_" stringByAppendingString:[[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
  Class testClass = objc_allocateClassPair(originalClass, name.UTF8String, 0);
  XCTAssertNotNil(testClass);
  if (testClass == Nil) return;
  SEL setter = @selector(setTextContainerInset:);
  Method originalMethod = class_getInstanceMethod(originalClass, setter);
  XCTAssertNotEqual(originalMethod, (Method)NULL);
  if (originalMethod == NULL) { objc_disposeClassPair(testClass); return; }
  BOOL added = class_addMethod(testClass, setter, (IMP)ASBlockingTextViewInsetSetter, method_getTypeEncoding(originalMethod));
  XCTAssertTrue(added);
  if (!added) { objc_disposeClassPair(testClass); return; }
  objc_registerClassPair(testClass);
  ASInsetSetterGate *gate = [ASInsetSetterGate new];
  gate.entered = dispatch_semaphore_create(0);
  gate.readFinished = dispatch_semaphore_create(0);
  objc_setAssociatedObject(view, &ASInsetSetterGateKey, gate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  object_setClass(view, testClass);
  __block ASEditableTextInsetSnapshot observed = {};
  __block long entryResult = -1;
  XCTestExpectation *reads = [self expectationWithDescription:@"snapshot read during loaded inset update"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    entryResult = dispatch_semaphore_wait(gate.entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (entryResult == 0) {
      observed = node.textContainerInsetSnapshot;
    }
    dispatch_semaphore_signal(gate.readFinished);
    [reads fulfill];
  });
  UIEdgeInsets expected = UIEdgeInsetsMake(5, 6, 7, 8);
  node.textContainerInset = expected;
  [self waitForExpectations:@[reads] timeout:10.0];
  object_setClass(view, originalClass);
  objc_setAssociatedObject(view, &ASInsetSetterGateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  XCTAssertEqual(entryResult, 0);
  XCTAssertEqual(gate.waitResult, 0);
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(observed.inset, expected));
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(view.textContainerInset, node.textContainerInsetSnapshot.inset));
}

- (void)testInitialScrollStateMatchesLegacyBeforeAndAfterViewLoading
{
  for (NSNumber *value in @[@NO, @YES]) {
    BOOL scrollEnabled = value.boolValue;
    ASEditableTextNode *legacy = [[ASEditableTextNode alloc] init];
    legacy.scrollEnabled = scrollEnabled;
    __block ASEditableTextNode *candidate = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      candidate = [[ASEditableTextNode alloc] initWithInitialScrollEnabled:scrollEnabled];
      dispatch_semaphore_signal(done);
    });
    long result = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    XCTAssertEqual(result, 0);
    if (result != 0) return;
    XCTAssertFalse(candidate.nodeLoaded);
    XCTAssertEqual(candidate.scrollEnabled, legacy.scrollEnabled);
    UITextView *candidateView = candidate.textView;
    UITextView *legacyView = legacy.textView;
    XCTAssertEqual(candidateView.scrollEnabled, legacyView.scrollEnabled);
    XCTAssertEqual(candidateView.scrollsToTop, legacyView.scrollsToTop);
    XCTAssertEqual(candidateView.panGestureRecognizer.enabled, legacyView.panGestureRecognizer.enabled);
    XCTAssertEqual([candidateView gestureRecognizerShouldBegin:candidateView.panGestureRecognizer],
                   [legacyView gestureRecognizerShouldBegin:legacyView.panGestureRecognizer]);
    candidate.scrollEnabled = !scrollEnabled;
    legacy.scrollEnabled = !scrollEnabled;
    XCTAssertEqual(candidateView.scrollsToTop, legacyView.scrollsToTop);
    XCTAssertEqual(candidateView.scrollEnabled, legacyView.scrollEnabled);
    XCTAssertEqual([candidateView gestureRecognizerShouldBegin:candidateView.panGestureRecognizer],
                   [legacyView gestureRecognizerShouldBegin:legacyView.panGestureRecognizer]);
  }
}

- (void)testSubclassCanInitializeWithScrollingDisabled
{
  ASInitiallyNonScrollingTextNode *node = [[ASInitiallyNonScrollingTextNode alloc] init];
  XCTAssertNotNil(node);
  XCTAssertFalse(node.nodeLoaded);
  XCTAssertFalse(node.scrollEnabled);
  XCTAssertFalse(node.textView.scrollsToTop);
}

- (void)testColdInitialTextAndInsetsMatchLegacyBeforeAndAfterLoading
{
  NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"12.04.2025"
                                                             attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:17]}];
  UIEdgeInsets insets = UIEdgeInsetsMake(7, 7, 7, 7);
  ASEditableTextNode *legacy = [[ASEditableTextNode alloc] init];
  legacy.textContainerInset = insets;
  legacy.attributedText = text;

  __block ASEditableTextNode *cold = nil;
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    cold = [ASEditableTextNode coldNodeWithInitialAttributedText:text textContainerInset:insets];
    dispatch_semaphore_signal(finished);
  });
  long waitResult = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
  XCTAssertEqual(waitResult, 0);
  if (waitResult != 0) { return; }
  XCTAssertNotNil(cold);
  if (cold == nil) { return; }
  XCTAssertFalse(cold.nodeLoaded);
  XCTAssertEqualObjects(cold.attributedText, legacy.attributedText);
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(cold.textContainerInset, legacy.textContainerInset));
  ASSizeRange range = ASSizeRangeMake(CGSizeZero, CGSizeMake(150, 100));
  XCTAssertTrue(CGSizeEqualToSize([cold layoutThatFits:range].size, [legacy layoutThatFits:range].size));
  XCTAssertEqualObjects(cold.textView.attributedText, legacy.textView.attributedText);
  XCTAssertTrue(UIEdgeInsetsEqualToEdgeInsets(cold.textView.textContainerInset, legacy.textView.textContainerInset));
}

- (void)testMeasuredLinesAreImmutableAndReadableOnWorkerBeforeAndAfterLoad
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  node.attributedText = self.attributedText;
  node.maximumLinesToDisplay = 3;
  [node calculateSizeThatFits:CGSizeMake(120, CGFLOAT_MAX)];
  NSArray<NSValue *> *expected = node.linesInfo;
  XCTAssertGreaterThan(expected.count, 0u);
  XCTAssertFalse([expected isKindOfClass:[NSMutableArray class]]);

  for (NSUInteger iteration = 0; iteration < 2; ++iteration) {
    if (iteration == 1) {
      (void)node.view;
      node.attributedText = [[NSAttributedString alloc] initWithString:@"Updated text after loading with multiple lines to measure."];
      [node calculateSizeThatFits:CGSizeMake(80, CGFLOAT_MAX)];
      expected = node.linesInfo;
      XCTAssertGreaterThan(expected.count, 0u);
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray<NSValue *> *actual = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      actual = node.linesInfo;
      dispatch_semaphore_signal(done);
    });
    XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)), 0);
    XCTAssertEqualObjects(actual, expected);
  }
}

- (void)testLineLimitCanChangeWhileTextIsMeasuredOnWorker
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  node.attributedText = self.attributedText;
  XCTestExpectation *writersDone = [self expectationWithDescription:@"line limit updates completed"];
  XCTestExpectation *measurementsDone = [self expectationWithDescription:@"measurements completed"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (NSUInteger index = 0; index < 200; ++index) {
      [node updateLineLimitForMeasurement:index % 4];
      (void)node.maximumLinesToDisplay;
    }
    [writersDone fulfill];
  });
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    for (NSUInteger index = 0; index < 200; ++index) {
      CGSize size = [node calculateSizeThatFits:CGSizeMake(120, CGFLOAT_MAX)];
      XCTAssertTrue(isfinite(size.width) && isfinite(size.height));
    }
    [measurementsDone fulfill];
  });
  [self waitForExpectations:@[writersDone, measurementsDone] timeout:10.0];
  node.maximumLinesToDisplay = 3;
  CGSize measured = [node calculateSizeThatFits:CGSizeMake(120, CGFLOAT_MAX)];
  XCTAssertEqual(node.maximumLinesToDisplay, 3u);
  // The extra line signals that text is truncated to the requested limit.
  XCTAssertEqual(node.linesInfo.count, 4u);
  ASEditableTextNode *reference = [[ASEditableTextNode alloc] init];
  reference.attributedText = self.attributedText;
  reference.maximumLinesToDisplay = 3;
  CGSize referenceSize = [reference calculateSizeThatFits:CGSizeMake(120, CGFLOAT_MAX)];
  XCTAssertTrue(CGSizeEqualToSize(measured, referenceSize));
  XCTAssertEqualObjects(node.linesInfo, reference.linesInfo);
}

- (void)testLineLimitSnapshotDetectsRepeatedAndABAAssignments
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  node.maximumLinesToDisplay = 1;
  ASEditableTextLineLimitSnapshot initial = node.lineLimitSnapshot;
  [node updateLineLimitForMeasurement:2];
  node.maximumLinesToDisplay = 1;
  ASEditableTextLineLimitSnapshot afterABA = node.lineLimitSnapshot;
  XCTAssertEqual(afterABA.maximumLinesToDisplay, initial.maximumLinesToDisplay);
  XCTAssertGreaterThan(afterABA.revision, initial.revision);
  node.maximumLinesToDisplay = 1;
  XCTAssertGreaterThan(node.lineLimitSnapshot.revision, afterABA.revision);
}

- (void)testLineLimitLockIsReleasedBeforeLayoutInvalidation
{
  ASLineLimitBlockedLayoutNode *node = [[ASLineLimitBlockedLayoutNode alloc] init];
  node.attributedText = self.attributedText;
  node.measurementEntered = dispatch_semaphore_create(0);
  node.continueMeasurement = dispatch_semaphore_create(0);
  dispatch_group_t tasks = dispatch_group_create();
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_group_async(tasks, queue, ^{
    [node layoutThatFits:ASSizeRangeMake(CGSizeMake(120, 0), CGSizeMake(120, CGFLOAT_MAX))];
  });
  long entered = dispatch_semaphore_wait(node.measurementEntered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
  if (entered != 0) {
    dispatch_semaphore_signal(node.continueMeasurement);
    XCTFail(@"layout did not enter measurement");
    return;
  }
  dispatch_group_async(tasks, queue, ^{ [node updateLineLimitForMeasurement:2]; });
  dispatch_semaphore_t valueVisible = dispatch_semaphore_create(0);
  dispatch_group_async(tasks, queue, ^{
    for (NSUInteger attempt = 0; attempt < 3000; ++attempt) {
      if (node.lineLimitSnapshot.maximumLinesToDisplay == 2) {
        dispatch_semaphore_signal(valueVisible);
        return;
      }
      [NSThread sleepForTimeInterval:0.001];
    }
  });
  long observed = dispatch_semaphore_wait(valueVisible, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  dispatch_semaphore_signal(node.continueMeasurement);
  long completed = dispatch_group_wait(tasks, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
  XCTAssertEqual(observed, 0, @"line limit lock was held while waiting for layout invalidation");
  XCTAssertEqual(completed, 0);
}

- (void)testPublishedLinesDoNotChangeWhenSourceArrayIsMutated
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  NSMutableArray<NSValue *> *source = [NSMutableArray arrayWithObject:[NSValue valueWithCGRect:CGRectMake(0, 0, 20, 10)]];
  [node setValue:source forKey:@"linesInfo"];
  [source addObject:[NSValue valueWithCGRect:CGRectMake(0, 10, 20, 10)]];
  XCTAssertEqual(node.linesInfo.count, 1u);
}

- (void)testReplacingLinesReleasesPreviousValuesOutsideSnapshotLock
{
  ASEditableTextNode *node = [[ASEditableTextNode alloc] init];
  XCTestExpectation *released = [self expectationWithDescription:@"previous lines released"];
  __weak ASEditableTextNode *weakNode = node;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    @autoreleasepool {
      ASMeasurementLinesDeinitProbe *probe = [[ASMeasurementLinesDeinitProbe alloc] init];
      probe.onDealloc = ^{
        (void)weakNode.linesInfo;
        [released fulfill];
      };
      [node setValue:@[probe] forKey:@"linesInfo"];
    }
    [node setValue:nil forKey:@"linesInfo"];
  });
  [self waitForExpectations:@[released] timeout:3.0];
}

#pragma mark - ASEditableTextNode Tests

- (void)testUITextInputTraitDefaults
{
  ASEditableTextNode *editableTextNode = [[ASEditableTextNode alloc] init];
  
  XCTAssertTrue(editableTextNode.autocapitalizationType == UITextAutocapitalizationTypeSentences, @"_ASTextInputTraitsPendingState's autocapitalizationType default should be UITextAutocapitalizationTypeSentences.");
  XCTAssertTrue(editableTextNode.autocorrectionType == UITextAutocorrectionTypeDefault,           @"_ASTextInputTraitsPendingState's autocorrectionType default should be UITextAutocorrectionTypeDefault.");
  XCTAssertTrue(editableTextNode.spellCheckingType == UITextSpellCheckingTypeDefault,             @"_ASTextInputTraitsPendingState's spellCheckingType default should be UITextSpellCheckingTypeDefault.");
  XCTAssertTrue(editableTextNode.keyboardType == UIKeyboardTypeDefault,                           @"_ASTextInputTraitsPendingState's keyboardType default should be UIKeyboardTypeDefault.");
  XCTAssertTrue(editableTextNode.keyboardAppearance == UIKeyboardAppearanceDefault,               @"_ASTextInputTraitsPendingState's keyboardAppearance default should be UIKeyboardAppearanceDefault.");
  XCTAssertTrue(editableTextNode.returnKeyType == UIReturnKeyDefault,                             @"_ASTextInputTraitsPendingState's returnKeyType default should be UIReturnKeyDefault.");
  XCTAssertTrue(editableTextNode.enablesReturnKeyAutomatically == NO,                             @"_ASTextInputTraitsPendingState's enablesReturnKeyAutomatically default should be NO.");
  XCTAssertTrue(editableTextNode.isSecureTextEntry == NO,                                         @"_ASTextInputTraitsPendingState's isSecureTextEntry default should be NO.");
  
  XCTAssertTrue(editableTextNode.textView.autocapitalizationType == UITextAutocapitalizationTypeSentences, @"textView's autocapitalizationType default should be UITextAutocapitalizationTypeSentences.");
  XCTAssertTrue(editableTextNode.textView.autocorrectionType == UITextAutocorrectionTypeDefault,           @"textView's autocorrectionType default should be UITextAutocorrectionTypeDefault.");
  XCTAssertTrue(editableTextNode.textView.spellCheckingType == UITextSpellCheckingTypeDefault,             @"textView's spellCheckingType default should be UITextSpellCheckingTypeDefault.");
  XCTAssertTrue(editableTextNode.textView.keyboardType == UIKeyboardTypeDefault,                           @"textView's keyboardType default should be UIKeyboardTypeDefault.");
  XCTAssertTrue(editableTextNode.textView.keyboardAppearance == UIKeyboardAppearanceDefault,               @"textView's keyboardAppearance default should be UIKeyboardAppearanceDefault.");
  XCTAssertTrue(editableTextNode.textView.returnKeyType == UIReturnKeyDefault,                             @"textView's returnKeyType default should be UIReturnKeyDefault.");
  XCTAssertTrue(editableTextNode.textView.enablesReturnKeyAutomatically == NO,                             @"textView's enablesReturnKeyAutomatically default should be NO.");
  XCTAssertTrue(editableTextNode.textView.isSecureTextEntry == NO,                                         @"textView's isSecureTextEntry default should be NO.");
}

- (void)testUITextInputTraitsSetTraitsBeforeViewLoaded
{
  // UITextView ignores any values set on the first 3 properties below if secureTextEntry is enabled.
  // Because of this UIKit behavior, we'll test secure entry seperately
  ASEditableTextNode *editableTextNode = [[ASEditableTextNode alloc] init];
  
  editableTextNode.autocapitalizationType = UITextAutocapitalizationTypeWords;
  editableTextNode.autocorrectionType = UITextAutocorrectionTypeYes;
  editableTextNode.spellCheckingType = UITextSpellCheckingTypeYes;
  editableTextNode.keyboardType = UIKeyboardTypeTwitter;
  editableTextNode.keyboardAppearance = UIKeyboardAppearanceDark;
  editableTextNode.returnKeyType = UIReturnKeyGo;
  editableTextNode.enablesReturnKeyAutomatically = YES;

  XCTAssertTrue(editableTextNode.textView.autocapitalizationType == UITextAutocapitalizationTypeWords, @"textView's autocapitalizationType should be UITextAutocapitalizationTypeAllCharacters.");
  XCTAssertTrue(editableTextNode.textView.autocorrectionType == UITextAutocorrectionTypeYes,           @"textView's autocorrectionType should be UITextAutocorrectionTypeYes.");
  XCTAssertTrue(editableTextNode.textView.spellCheckingType == UITextSpellCheckingTypeYes,             @"textView's spellCheckingType should be UITextSpellCheckingTypeYes.");
  XCTAssertTrue(editableTextNode.textView.keyboardType == UIKeyboardTypeTwitter,                       @"textView's keyboardType should be UIKeyboardTypeTwitter.");
  XCTAssertTrue(editableTextNode.textView.keyboardAppearance == UIKeyboardAppearanceDark,              @"textView's keyboardAppearance should be UIKeyboardAppearanceDark.");
  XCTAssertTrue(editableTextNode.textView.returnKeyType == UIReturnKeyGo,                              @"textView's returnKeyType should be UIReturnKeyGo.");
  XCTAssertTrue(editableTextNode.textView.enablesReturnKeyAutomatically == YES,                        @"textView's enablesReturnKeyAutomatically should be YES.");
  
  ASEditableTextNode *secureEditableTextNode = [[ASEditableTextNode alloc] init];
  secureEditableTextNode.secureTextEntry = YES;
  
  XCTAssertTrue(secureEditableTextNode.textView.secureTextEntry == YES,                                @"textView's isSecureTextEntry should be YES.");
}

- (void)testUITextInputTraitsChangeTraitAfterViewLoaded
{
  // UITextView ignores any values set on the first 3 properties below if secureTextEntry is enabled.
  // Because of this UIKit behavior, we'll test secure entry seperately
  ASEditableTextNode *editableTextNode = [[ASEditableTextNode alloc] init];

  editableTextNode.textView.autocapitalizationType = UITextAutocapitalizationTypeWords;
  editableTextNode.textView.autocorrectionType = UITextAutocorrectionTypeYes;
  editableTextNode.textView.spellCheckingType = UITextSpellCheckingTypeYes;
  editableTextNode.textView.keyboardType = UIKeyboardTypeTwitter;
  editableTextNode.textView.keyboardAppearance = UIKeyboardAppearanceDark;
  editableTextNode.textView.returnKeyType = UIReturnKeyGo;
  editableTextNode.textView.enablesReturnKeyAutomatically = YES;
  
  XCTAssertTrue(editableTextNode.textView.autocapitalizationType == UITextAutocapitalizationTypeWords, @"textView's autocapitalizationType should be UITextAutocapitalizationTypeAllCharacters.");
  XCTAssertTrue(editableTextNode.textView.autocorrectionType == UITextAutocorrectionTypeYes,           @"textView's autocorrectionType should be UITextAutocorrectionTypeYes.");
  XCTAssertTrue(editableTextNode.textView.spellCheckingType == UITextSpellCheckingTypeYes,             @"textView's spellCheckingType should be UITextSpellCheckingTypeYes.");
  XCTAssertTrue(editableTextNode.textView.keyboardType == UIKeyboardTypeTwitter,                       @"textView's keyboardType should be UIKeyboardTypeTwitter.");
  XCTAssertTrue(editableTextNode.textView.keyboardAppearance == UIKeyboardAppearanceDark,              @"textView's keyboardAppearance should be UIKeyboardAppearanceDark.");
  XCTAssertTrue(editableTextNode.textView.returnKeyType == UIReturnKeyGo,                              @"textView's returnKeyType should be UIReturnKeyGo.");
  XCTAssertTrue(editableTextNode.textView.enablesReturnKeyAutomatically == YES,                        @"textView's enablesReturnKeyAutomatically should be YES.");
  
  ASEditableTextNode *secureEditableTextNode = [[ASEditableTextNode alloc] init];
  secureEditableTextNode.textView.secureTextEntry = YES;
  
  XCTAssertTrue(secureEditableTextNode.textView.secureTextEntry == YES,                                @"textView's isSecureTextEntry should be YES.");
}

- (void)testCalculatedSizeIsGreaterThanOrEqualToConstrainedSize
{
  for (NSInteger i = 10; i < 500; i += 50) {
    CGSize constrainedSize = CGSizeMake(i, i);
    CGSize calculatedSize = [_editableTextNode layoutThatFits:ASSizeRangeMake(CGSizeZero, constrainedSize)].size;
    XCTAssertTrue(calculatedSize.width <= constrainedSize.width, @"Calculated width (%f) should be less than or equal to constrained width (%f)", calculatedSize.width, constrainedSize.width);
    XCTAssertTrue(calculatedSize.height <= constrainedSize.height, @"Calculated height (%f) should be less than or equal to constrained height (%f)", calculatedSize.height, constrainedSize.height);
  }
}

- (void)testRecalculationOfSizeIsSameAsOriginallyCalculatedSize
{
  for (NSInteger i = 10; i < 500; i += 50) {
    CGSize constrainedSize = CGSizeMake(i, i);
    CGSize calculatedSize = [_editableTextNode layoutThatFits:ASSizeRangeMake(CGSizeZero, constrainedSize)].size;
    CGSize recalculatedSize = [_editableTextNode layoutThatFits:ASSizeRangeMake(CGSizeZero, constrainedSize)].size;
    
    XCTAssertTrue(CGSizeEqualToSizeWithIn(calculatedSize, recalculatedSize, 4.0), @"Recalculated size %@ should be same as original size %@", NSStringFromCGSize(recalculatedSize), NSStringFromCGSize(calculatedSize));
  }
}

- (void)testRecalculationOfSizeIsSameAsOriginallyCalculatedFloatingPointSize
{
  for (CGFloat i = 10; i < 500; i *= 1.3) {
    CGSize constrainedSize = CGSizeMake(i, i);
    CGSize calculatedSize = [_editableTextNode layoutThatFits:ASSizeRangeMake(CGSizeZero, constrainedSize)].size;
    CGSize recalculatedSize = [_editableTextNode layoutThatFits:ASSizeRangeMake(CGSizeZero, constrainedSize)].size;

    XCTAssertTrue(CGSizeEqualToSizeWithIn(calculatedSize, recalculatedSize, 11.0), @"Recalculated size %@ should be same as original size %@", NSStringFromCGSize(recalculatedSize), NSStringFromCGSize(calculatedSize));
  }
}

@end
