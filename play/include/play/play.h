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
