/* SPDX-License-Identifier: MIT
 * The games' plain C interface (native/play.cpp, built into lib/libplay.dylib): one NES, one
 * NetHack and one Doom a process. Errors come back as a negative number, with what went
 * wrong written into `error` where there is one. */
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

  /* The NES: a libretro core and a game (.nes). Buttons are play::button bits (libretro's
   * joypad ids: B 0, Select 2, Start 3, Up 4, Down 5, Left 6, Right 7, A 8). */
  int play_nes_open(char const *core, char const *game, char *error, int size);
  int play_nes_run(unsigned buttons, unsigned frames);
  /* The same with the second controller's buttons too (two players). */
  int play_nes_run2(unsigned buttons, unsigned buttons2, unsigned frames);
  long long play_nes_frames(void);
  int play_nes_ram(unsigned char *out, int max);
  int play_nes_cartridge_ram(unsigned char *out, int max);
  int play_nes_picture(uint32_t *out, int max, int *width, int *height, uint64_t *version);
  int play_nes_save(unsigned char *out, int max);
  int play_nes_restore(unsigned char const *state, int size);

  /* NetHack: the NetHack Learning Environment's libnethack.so (a copy is loaded), its game
   * files' directory, its options, a seed. A step is a key. */
  int play_nethack_open(char const *library, char const *hackdir, char const *options, unsigned long seed,
                        char *error, int size);
  int play_nethack_step(int key);
  int play_nethack_screen(char *chars, signed char *colors, int *cursor_row, int *cursor_col, uint64_t *version);
  int play_nethack_status(long *stats, char *message, int *in_normal_game, int *done);
  int play_nethack_inventory(char *out, int max);
  void play_nethack_close(void);

  /* Doom: ViZDoom's engine (a program), a game's data (.wad), a map, a seed, the picture's
   * width (320 or 640). */
  int play_doom_open(char const *engine, char const *wad, char const *map, unsigned seed, int width, char *error,
                     int size);
  double play_doom_act(unsigned buttons, int tics);
  int play_doom_finished(void);
  int play_doom_state(double *variables, int max, int *tic, char *objects, int size);
  int play_doom_rays(double *out, int max);
  // The sectors' floor and ceiling heights kept now, for play_doom_moved.
  void play_doom_mark();
  // A console command given to Doom (for checks: give health, god), done on the next tic.
  void play_doom_command(char const *command);
  // The map's exits: each exit line's middle x, y and how it is set off (1 walking over it, 2
  // using it), three numbers an exit; the count.
  int play_doom_exits(double *out, int max);
  // The way to the nearest sector the player hasn't stood in, sector to sector across the
  // lines they share that the player can cross (room to stand, a step up of at most 24, or a
  // door): the middles of those lines, x and y each, into `out`; their count (0: none found).
  int play_doom_frontier(double *out, int max);
  // 1 when nothing of the map (a wall, a closed door, a floor or ceiling past the eyes) is
  // between the player's eyes and point x, y (lines as the last rays saw them), else 0.
  int play_doom_sees(double x, double y);
  // The monsters anywhere in the map, seen or not, a line each: name x y.
  int play_doom_monsters(char *out, int size);
  // The sectors whose floor or ceiling moved since play_doom_mark: each one's middle x, y and
  // its floor's and ceiling's change, four numbers a sector; the count.
  int play_doom_moved(double *out, int max);
  /* The NES's last frame run (not the one shown: frames are shown at the game's own speed,
     queued), and a picture shown at once in place of the queued ones (a restored state's). */
  int play_nes_latest(uint32_t *out, int max, int *width, int *height);
  void play_nes_show(uint32_t const *picture, int n, int width, int height);
  /* The NES's frames run and not yet shown, and those dropped for the last one run. */
  int play_nes_queued(void);
  void play_nes_flush(void);
  int play_doom_picture(uint32_t *out, int max, int *width, int *height, uint64_t *version);
  void play_doom_close(void);

#ifdef __cplusplus
}
#endif
