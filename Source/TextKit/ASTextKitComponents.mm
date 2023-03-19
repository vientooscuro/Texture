//
//  ASTextKitComponents.mm
//  Texture
//
//  Copyright (c) Facebook, Inc. and its affiliates.  All rights reserved.
//  Changes after 4/13/2017 are: Copyright (c) Pinterest, Inc.  All rights reserved.
//  Licensed under Apache 2.0: http://www.apache.org/licenses/LICENSE-2.0
//

#import <AsyncDisplayKit/ASTextKitComponents.h>
#import <AsyncDisplayKit/ASAssert.h>

#import <tgmath.h>

@interface ASTextKitComponentsTextView () {
  // Prevent UITextView from updating contentOffset while deallocating: https://github.com/TextureGroup/Texture/issues/860
  BOOL _deallocating;
}
@property CGRect threadSafeBounds;
@end

@implementation ASTextKitComponentsTextView

- (instancetype)initWithFrame:(CGRect)frame textContainer:(NSTextContainer *)textContainer
{
  self = [super initWithFrame:frame textContainer:textContainer];
  if (self) {
    _threadSafeBounds = self.bounds;
    _deallocating = NO;
  }
  return self;
}

- (void)dealloc
{
  _deallocating = YES;
}

- (void)setFrame:(CGRect)frame
{
  ASDisplayNodeAssertMainThread();
  [super setFrame:frame];
  self.threadSafeBounds = self.bounds;
}

- (void)setBounds:(CGRect)bounds
{
  ASDisplayNodeAssertMainThread();
  [super setBounds:bounds];
  self.threadSafeBounds = bounds;
}

- (void)setContentOffset:(CGPoint)contentOffset
{
  if (_deallocating) {
    return;
  }
  
  [super setContentOffset:contentOffset];
}


@end

@interface ASTextKitComponents ()

// read-write redeclarations
@property (nonatomic) NSTextStorage *textStorage;
@property (nonatomic) NSTextContainer *textContainer;
@property (nonatomic) NSLayoutManager *layoutManager;

@end

@implementation ASTextKitComponents

#pragma mark - Class

+ (instancetype)componentsWithAttributedSeedString:(NSAttributedString *)attributedSeedString
                                 textContainerSize:(CGSize)textContainerSize NS_RETURNS_RETAINED
{
  NSTextStorage *textStorage = attributedSeedString ? [[NSTextStorage alloc] initWithAttributedString:attributedSeedString] : [[NSTextStorage alloc] init];

  return [self componentsWithTextStorage:textStorage
                       textContainerSize:textContainerSize
                           layoutManager:[[NSLayoutManager alloc] init]];
}

+ (instancetype)componentsWithTextStorage:(NSTextStorage *)textStorage
                        textContainerSize:(CGSize)textContainerSize
                            layoutManager:(NSLayoutManager *)layoutManager NS_RETURNS_RETAINED
{
  ASTextKitComponents *components = [[self alloc] init];

  components.textStorage = textStorage;

  components.layoutManager = layoutManager;
  [components.textStorage addLayoutManager:components.layoutManager];

  components.textContainer = [[NSTextContainer alloc] initWithSize:textContainerSize];
  components.textContainer.lineFragmentPadding = 0.0; // We want the text laid out up to the very edges of the text-view.
  [components.layoutManager addTextContainer:components.textContainer];

  return components;
}

+ (BOOL)needsMainThreadDeallocation
{
  return YES;
}

#pragma mark - Lifecycle

- (void)dealloc
{
  // Nil out all delegates to prevent crash
  if (_textView) {
    ASDisplayNodeAssertMainThread();
    _textView.delegate = nil;
  }
  _layoutManager.delegate = nil;
}

#pragma mark - Sizing

- (CGSize)sizeForConstrainedWidth:(CGFloat)constrainedWidth
{
  ASTextKitComponents *components = self;

  // If our text-view's width is already the constrained width, we can use our existing TextKit stack for this sizing calculation.
  // Otherwise, we create a temporary stack to size for `constrainedWidth`.
  if (CGRectGetWidth(components.textView.threadSafeBounds) != constrainedWidth) {
    components = [ASTextKitComponents componentsWithAttributedSeedString:components.textStorage textContainerSize:CGSizeMake(constrainedWidth, CGFLOAT_MAX)];
  }

  // Force glyph generation and layout, which may not have happened yet (and isn't triggered by -usedRectForTextContainer:).
  [components.layoutManager ensureLayoutForTextContainer:components.textContainer];
  CGSize textSize = [components.layoutManager usedRectForTextContainer:components.textContainer].size;

  return textSize;
}

- (CGSize)sizeForConstrainedWidth:(CGFloat)constrainedWidth
              forMaxNumberOfLines:(NSInteger)maxNumberOfLines {
  return [self sizeForConstrainedWidth:constrainedWidth forMaxNumberOfLines:maxNumberOfLines linesInfo:nil];
}

- (CGSize)sizeForConstrainedWidth:(CGFloat)constrainedWidth
              forMaxNumberOfLines:(NSInteger)maxNumberOfLines
                        linesInfo:(NSMutableArray<NSValue*>*_Nullable*_Nullable)linesInfo
{
  if (maxNumberOfLines == 0) {
    linesInfo = nil;
    return [self sizeForConstrainedWidth:constrainedWidth];
  }
  
  ASTextKitComponents *components = self;
  
  // Always use temporary stack in case of threading issues
  components = [ASTextKitComponents componentsWithAttributedSeedString:components.textStorage textContainerSize:CGSizeMake(constrainedWidth, CGFLOAT_MAX)];

  // Force glyph generation and layout, which may not have happened yet (and isn't triggered by - usedRectForTextContainer:).
  [components.layoutManager ensureLayoutForTextContainer:components.textContainer];
  
  CGFloat width = [components.layoutManager usedRectForTextContainer:components.textContainer].size.width;
  
  // Calculate height based on line fragments
  // Based on calculating number of lines from: http://asciiwwdc.com/2013/sessions/220
  NSRange glyphRange, lineRange = NSMakeRange(0, 0);
  CGRect rect = CGRectZero;
  CGFloat height = 0;
  CGFloat lastOriginY = -1.0;
  NSUInteger numberOfLines = 0;
  
  glyphRange = [components.layoutManager glyphRangeForTextContainer:components.textContainer];
  
  if (*linesInfo == nil) {
      // если *linesInfo == nil, создаем новый объект NSMutableArray<NSValue*>*
      *linesInfo = [NSMutableArray array];
  }
  
  auto lineSizes = *linesInfo;
  
  // теперь *linesInfo ссылается на созданный объект NSMutableArray<NSValue*>*,
  // поэтому мы можем добавить новые значения в массив
  NSValue *newValue = [NSValue valueWithCGSize:CGSizeMake(100, 200)];
  [*linesInfo addObject:newValue];

  
  while (lineRange.location < NSMaxRange(glyphRange)) {
    rect = [components.layoutManager lineFragmentRectForGlyphAtIndex:lineRange.location
                                                      effectiveRange:&lineRange];
    
    if (CGRectGetMinY(rect) > lastOriginY) {
      ++numberOfLines;
      [lineSizes addObject:[NSValue valueWithCGSize:rect.size]];
      if (numberOfLines == maxNumberOfLines) {
        height = rect.origin.y + rect.size.height;
      } else if (numberOfLines == maxNumberOfLines) {
        break;
      }
    }
    
    lastOriginY = CGRectGetMinY(rect);
    lineRange.location = NSMaxRange(lineRange);
  }
  
  CGFloat fragmentHeight = rect.origin.y + rect.size.height;
  CGFloat finalHeight = std::ceil(std::fmax(height, fragmentHeight));
  
  CGSize size = CGSizeMake(width, finalHeight);
  
  return size;
}

@end
