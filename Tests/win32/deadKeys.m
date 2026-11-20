/* Dead keys on win32 (Source/win32/WIN32Server.m): a key event's characters
 * must be what the keyboard layout makes of the key presses.
 *
 * A dead key (an accent that waits for the next key) is kept by Windows as
 * keyboard state, used up by the next key press. The back end makes a key
 * event's text with ToUnicodeEx in its WM_KEYDOWN handler; it used to run
 * TranslateMessage on the press first, which used the dead key up already,
 * and to call ToUnicodeEx again on the key's release and with no modifiers,
 * so "' then e" on a US International keyboard came out as "''" then "e"
 * instead of "é". These check:
 *  - a dead key then a letter it combines with gives the composed letter;
 *  - a dead key then space gives the accent alone;
 *  - a dead key then a letter it doesn't combine with gives both;
 *  - a dead key's own press gives no text;
 *  - a plain key is unchanged.
 *
 * It loads the US International layout for this thread and posts the key
 * messages to a window, so the window needn't be in front; it reads the key
 * events from the queue. It skips without that layout, or when the win32
 * display server isn't built.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#include "config.h"

#if defined(BUILD_SERVER) && defined(SERVER_win32) \
  && BUILD_SERVER == SERVER_win32

#import <AppKit/AppKit.h>
#include <windows.h>

/* Posts a press and release of the key VK to WINDOW, then returns the
   characters of the key-down events the back end made of them.  */
static NSString *
press(HWND window, HKL layout, UINT vk)
{
  NSMutableString *typed = [NSMutableString string];
  UINT scan = MapVirtualKeyExW(vk, MAPVK_VK_TO_VSC, layout);
  NSDate *until;
  NSEvent *event;

  PostMessageW(window, WM_KEYDOWN, vk, (LPARAM)(1 | (scan << 16)));
  PostMessageW(window, WM_KEYUP, vk,
    (LPARAM)(1 | (scan << 16) | (1u << 30) | (1u << 31)));
  until = [NSDate dateWithTimeIntervalSinceNow: 0.2];
  while ((event = [NSApp nextEventMatchingMask: NSKeyDownMask | NSKeyUpMask
                                     untilDate: until
                                        inMode: NSDefaultRunLoopMode
                                       dequeue: YES]) != nil)
    {
      if ([event type] == NSKeyDown)
	{
	  [typed appendString: [event characters]];
	}
    }
  return typed;
}

static NSString *
type(HWND window, HKL layout, UINT first, UINT second)
{
  NSString *text = press(window, layout, first);

  if (second != 0)
    {
      text = [text stringByAppendingString: press(window, layout, second)];
    }
  return text;
}

int
main(int argc, char **argv)
{
  CREATE_AUTORELEASE_POOL(arp);
  HKL layout;
  NSWindow *window;
  HWND hwnd;
  NSString *eAcute = [NSString stringWithFormat: @"%C", (unichar)0x00e9];

  START_SET("win32 dead keys")

  layout = LoadKeyboardLayoutW(L"00020409", KLF_ACTIVATE);
  if (layout == NULL || ActivateKeyboardLayout(layout, 0) == NULL)
    {
      SKIP("The US International keyboard layout can't be loaded")
    }

  NS_DURING
    [NSApplication sharedApplication];
  NS_HANDLER
    if ([[localException name] isEqualToString: @"SkipSet"])
      [localException raise];
    else
      {
	SKIP("The GNUstep backend could not start")
      }
  NS_ENDHANDLER

  window = AUTORELEASE([[NSWindow alloc]
    initWithContentRect: NSMakeRect(100, 100, 200, 100)
	      styleMask: NSTitledWindowMask
		backing: NSBackingStoreBuffered
		  defer: NO]);
  [window setReleasedWhenClosed: NO];
  [window orderFront: nil];
  hwnd = (HWND)(intptr_t)[window windowNumber];

  PASS_EQUAL(press(hwnd, layout, VK_OEM_7), @"",
    "a dead key's press gives no text");
  PASS_EQUAL(press(hwnd, layout, 'E'), eAcute,
    "the next letter, one it combines with, gives the composed letter (é)");
  PASS_EQUAL(type(hwnd, layout, VK_OEM_7, VK_SPACE), @"'",
    "a dead key then space gives the accent alone");
  PASS_EQUAL(type(hwnd, layout, VK_OEM_7, 'X'), @"'x",
    "a dead key then a letter it doesn't combine with gives both");
  PASS_EQUAL(type(hwnd, layout, 'A', 0), @"a",
    "a plain key is unchanged");

  [window close];

  END_SET("win32 dead keys")

  DESTROY(arp);
  return 0;
}

#else

int
main(int argc, char **argv)
{
  START_SET("win32 dead keys")
    SKIP("The win32 display server is not built")
  END_SET("win32 dead keys")
  return 0;
}

#endif
