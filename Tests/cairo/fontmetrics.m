/* A font from the cairo backend has to know the metrics that NSFont forwards
 * to it, which CairoFontInfo reads from its FreeType face.
 *
 * It needs a running window server to load the backend at all, so it skips
 * cleanly when there is none, and it guards on the cairo graphics backend.
 */
#import <Foundation/NSObject.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_GRAPHICS) && defined(GRAPHICS_cairo) \
  && BUILD_GRAPHICS == GRAPHICS_cairo

#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <math.h>

int
main(void)
{
  ENTER_POOL
  NSFont	*font;
  NSFont	*bigger;
  NSSize	least;
  NSSize	most;
  NSGlyph	glyph;
  BOOL		atLeast;

  START_SET("cairo font metrics")
  NS_DURING
    {
      [NSApplication sharedApplication];
      if (nil == GSCurrentServer())
	{
	  SKIP("no window server available")
	}
    }
  NS_HANDLER
    {
      SKIP("It looks like the GNUstep backend is not installed")
    }
  NS_ENDHANDLER

  font = [NSFont systemFontOfSize: 12];
  bigger = [NSFont systemFontOfSize: 24];
  PASS(font != nil && bigger != nil, "the system font exists")

  PASS([font isBaseFont], "a font is a base font")
  PASS([font numberOfGlyphs] > 0, "a font counts its glyphs")
  PASS([font underlinePosition] < 0, "the underline is below the baseline")
  PASS([font underlineThickness] > 0, "the underline has a thickness")
  PASS([font underlinePosition] > [font descender] - [font pointSize],
    "the underline is near the baseline")

  PASS(fabs([bigger underlineThickness] - 2 * [font underlineThickness]) < 0.51,
    "the underline scales with the size")
  PASS([bigger numberOfGlyphs] == [font numberOfGlyphs],
    "the size doesn't change the number of glyphs")

  least = [font minimumAdvancement];
  most = [font maximumAdvancement];
  PASS(least.width > 0, "the minimum advancement is positive")
  PASS(least.width <= most.width, "it's no more than the maximum")
  atLeast = YES;
  for (glyph = 1; glyph < 200 && glyph < [font numberOfGlyphs]; glyph++)
    {
      CGFloat	advance = [font advancementForGlyph: glyph].width;

      if (advance > 0 && advance + 0.01 < least.width)
	{
	  atLeast = NO;
	}
    }
  PASS(atLeast, "it's no more than the advance of any glyph")
  PASS(fabs([bigger minimumAdvancement].width - 2 * least.width) < 0.01,
    "it scales with the size")
  PASS([font minimumAdvancement].width == least.width, "it answers the same twice")

  END_SET("cairo font metrics")
  LEAVE_POOL
  return 0;
}

#else

int
main(void)
{
  START_SET("cairo font metrics")
  SKIP("back is not built with the cairo graphics backend")
  END_SET("cairo font metrics")
  return 0;
}

#endif
