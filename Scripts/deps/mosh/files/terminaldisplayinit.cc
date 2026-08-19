/* Sloop: curses-free replacement for mosh's Display constructor.

   Copied over the build tree's copy by Scripts/build-mosh.sh. Not a patch:
   nothing of upstream's version survives, and a diff that deletes a file's
   entire contents and writes new ones is harder to read than the file itself.

   Curses/terminfo enters mosh only through terminaldisplayinit.cc, which holds
   the single function `Display::Display(bool use_environment)` — deliberately
   kept in its own translation unit by upstream "because otherwise the ncurses
   #defines alias our own variable names." Everything else in terminaldisplay.cc
   (notably `Display::new_frame`, the Framebuffer→ANSI renderer) has no curses
   dependency, and Sloop's Mosh bridge reuses `new_frame` to render the remote
   framebuffer into SwiftTerm. `Terminal::Complete` embeds a `Display`, so both
   files must stay linkable.

   So: terminaldisplay.cc is kept verbatim and only this TU is replaced. The iOS
   SDK ships no terminfo database, and Sloop always constructs `Display(false)`,
   so the terminfo probing the real constructor does under `use_environment` is
   dead code here. This stub sets the same conservative capability defaults the
   real constructor starts from. */
#include "terminaldisplay.h"

using namespace Terminal;

Display::Display( bool use_environment )
  : has_ech( true ), has_bce( true ), has_title( true ), smcup( NULL ), rmcup( NULL )
{
  (void)use_environment;
}
