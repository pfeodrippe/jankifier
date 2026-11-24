// SPDX-License-Identifier: MIT
// The games behind a plain C interface (include/play/play.h), so that jank calls them
// whichever C++ library they were built with: an NES (a libretro core), NetHack (the NetHack
// Learning Environment) and Doom (ViZDoom). One of each a process. What jank calls runs on
// its REPL's thread; the window copies the pictures on its own, so each game has a lock.
#include <play/play.h>
#include <play/nes.hpp>

#include <ViZDoom.h>

extern "C"
{
#include <nledl.h>
}

#include <algorithm>
#include <array>
#include <chrono>
#include <deque>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <libproc.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace
{
  void say(char *error, int size, std::string const &what)
  {
    if(error && size > 0)
    {
      std::snprintf(error, static_cast<size_t>(size), "%s", what.c_str());
    }
  }

  // The NES.

  std::mutex nes_lock;
  std::unique_ptr<play::nes> nes_now;
  std::vector<uint32_t> nes_picture;
  unsigned nes_width{}, nes_height{};
  uint64_t nes_shown{}; // how many pictures there were: the window uploads a new one
  // The frames run and not yet shown: the window shows one each 1/60 s, so that a game is
  // seen at its own speed while it runs as fast as it goes (at most nes_queued_most kept:
  // the oldest are dropped when the game runs far ahead of what is seen).
  std::deque<std::vector<uint32_t>> nes_queued;
  size_t const nes_queued_most{ 120 };
  std::chrono::steady_clock::time_point nes_popped{};
  // The last frame run (what the console shows now, whatever is still queued).
  std::vector<uint32_t> nes_latest;

  // NetHack.

  constexpr int rows{ 21 }, cols{ 79 }; // NetHack's map: ROWNO x (COLNO - 1)
  std::mutex nethack_lock;
  nledl_ctx *nethack_now{};
  nle_obs nethack_obs{};
  nle_settings nethack_settings{};
  struct nethack_buffers
  {
    short glyphs[rows * cols];
    unsigned char chars[rows * cols], colors[rows * cols], specials[rows * cols];
    long blstats[NLE_BLSTATS_SIZE];
    unsigned char message[NLE_MESSAGE_SIZE];
    int program_state[NLE_PROGRAM_STATE_SIZE], internal[NLE_INTERNAL_SIZE], misc[NLE_MISC_SIZE];
    short inv_glyphs[NLE_INVENTORY_SIZE];
    unsigned char inv_strs[NLE_INVENTORY_SIZE * NLE_INVENTORY_STR_LENGTH];
    unsigned char inv_letters[NLE_INVENTORY_SIZE], inv_oclasses[NLE_INVENTORY_SIZE];
    unsigned char tty_chars[NLE_TERM_LI * NLE_TERM_CO];
    signed char tty_colors[NLE_TERM_LI * NLE_TERM_CO];
    unsigned char tty_cursor[2];
  };
  nethack_buffers nethack_b{};
  uint64_t nethack_steps{};

  void nethack_wire()
  {
    auto &o(nethack_obs);
    auto &b(nethack_b);
    o.glyphs = b.glyphs;
    o.chars = b.chars;
    o.colors = b.colors;
    o.specials = b.specials;
    o.blstats = b.blstats;
    o.message = b.message;
    o.program_state = b.program_state;
    o.internal = b.internal;
    o.misc = b.misc;
    o.inv_glyphs = b.inv_glyphs;
    o.inv_strs = b.inv_strs;
    o.inv_letters = b.inv_letters;
    o.inv_oclasses = b.inv_oclasses;
    o.tty_chars = b.tty_chars;
    o.tty_colors = b.tty_colors;
    o.tty_cursor = b.tty_cursor;
  }

  // Doom.

  std::mutex doom_lock;
  std::unique_ptr<vizdoom::DoomGame> doom_now;
  std::vector<uint32_t> doom_picture;
  // Doom's tics' pictures not yet shown: one each 1/35 s (its own rate), at most 70 kept.
  std::deque<std::vector<uint32_t>> doom_queued;
  std::chrono::steady_clock::time_point doom_popped{};
  unsigned doom_width{}, doom_height{};
  uint64_t doom_shown{};
  std::vector<double> doom_vars;
  std::string doom_objects;
  int doom_tic{};
  std::vector<vizdoom::GameVariable> const doom_variables{ vizdoom::HEALTH,     vizdoom::ARMOR,     vizdoom::AMMO2,
                                                           vizdoom::POSITION_X, vizdoom::POSITION_Y, vizdoom::ANGLE,
                                                           vizdoom::KILLCOUNT,  vizdoom::ITEMCOUNT, vizdoom::DEAD };
  std::vector<vizdoom::Button> const doom_buttons{ vizdoom::MOVE_FORWARD, vizdoom::MOVE_BACKWARD, vizdoom::TURN_LEFT,
                                                   vizdoom::TURN_RIGHT,   vizdoom::ATTACK,        vizdoom::USE,
                                                   vizdoom::MOVE_LEFT,    vizdoom::MOVE_RIGHT };

  // How far the player can walk in some directions (degrees to the left of where it faces),
  // from the map's lines: a line stops it when it is one-sided or impassable, or when the
  // opening between its two sectors is lower than the player (56 units); a door is a line of
  // a sector whose ceiling is down on its floor.
  // Multiples of a turn (30 degrees: play.doom's turn-left and turn-right), and behind.
  std::array<double, 8> const doom_ray_angles{ 90, 60, 30, 0, -30, -60, -90, 180 };
  // Each direction's distance and whether a closed door ends it.
  // Each ray's distance and what ends it: 0 a wall, 1 a door, 2 the exit, 3 something else
  // a player uses (a switch).
  std::vector<std::pair<double, int>> doom_rays;

  // What a line's use special (patches/vizdoom-use-specials.patch) makes it: doom_rays' kinds.
  int use_kind(int const special)
  {
    switch(special)
    {
      case 0:
        return 0;
      case 10: // Door_Close
      case 11: // Door_Open
      case 12: // Door_Raise
      case 13: // Door_LockedRaise
      case 14: // Door_Animated
      case 202: // Generic_Door
      case 249: // Door_CloseWaitOpen
        return 1;
      case 243: // Exit_Normal
      case 244: // Exit_Secret
        return 2;
      default:
        return 3;
    }
  }

  void doom_cast(vizdoom::GameState const &state, double const px, double const py, double const angle)
  {
    struct wall
    {
      double x1, y1, x2, y2;
      bool blocking;
      double ceiling, floor;
      int kind;
    };
    // A line is in each of its sectors' lists: keyed by its ends, either way round.
    std::map<std::array<long long, 4>, wall> walls;
    for(auto const &sector : state.sectors)
    {
      for(auto const &l : sector.lines)
      {
        std::array<long long, 4> key{ std::llround(l.x1), std::llround(l.y1), std::llround(l.x2), std::llround(l.y2) };
        if(std::make_pair(key[2], key[3]) < std::make_pair(key[0], key[1]))
        {
          key = { key[2], key[3], key[0], key[1] };
        }
        int const kind{ use_kind(l.useSpecial) };
        auto const at(walls.find(key));
        if(at == walls.end())
        {
          walls.emplace(key, wall{ l.x1, l.y1, l.x2, l.y2, l.isBlocking, sector.ceilingHeight, sector.floorHeight, kind });
        }
        else
        {
          auto &w(at->second);
          w.blocking = w.blocking || l.isBlocking;
          w.ceiling = std::min(w.ceiling, sector.ceilingHeight);
          w.floor = std::max(w.floor, sector.floorHeight);
          w.kind = std::max(w.kind, kind);
        }
      }
    }
    doom_rays.clear();
    for(double const a : doom_ray_angles)
    {
      double const th{ (angle + a) * M_PI / 180.0 };
      double const dx{ std::cos(th) }, dy{ std::sin(th) };
      double best{ 2048.0 };
      int kind{};
      for(auto const &[_, w] : walls)
      {
        if(!w.blocking && w.ceiling - w.floor >= 56.0)
        {
          continue;
        }
        // The ray p + t d meets the line a + u e (0 <= u <= 1) where t d - u e = a - p.
        double const ex{ w.x2 - w.x1 }, ey{ w.y2 - w.y1 };
        double const det{ ex * dy - dx * ey };
        if(std::abs(det) < 1e-9)
        {
          continue;
        }
        double const wx{ w.x1 - px }, wy{ w.y1 - py };
        double const t{ (ex * wy - wx * ey) / det };
        double const u{ (dx * wy - dy * wx) / det };
        if(t > 0.0 && u >= 0.0 && u <= 1.0 && t < best)
        {
          best = t;
          kind = w.kind;
        }
      }
      doom_rays.emplace_back(best, kind);
    }
  }

  // What the last state of Doom shows: its picture (queued), variables and objects in view,
  // and with `rays`, how far the player can walk each way.
  void doom_take(bool const rays = true)
  {
    auto const state(doom_now->getState());
    if(!state)
    {
      return;
    }
    doom_tic = state->number;
    doom_vars = state->gameVariables;
    if(rays && doom_vars.size() > 5)
    {
      doom_cast(*state, doom_vars[3], doom_vars[4], doom_vars[5]);
    }
    std::string objects;
    for(auto const &l : state->labels)
    {
      if(l.objectName == "DoomPlayer")
      {
        continue;
      }
      char line[256];
      std::snprintf(line, sizeof line, "%s %.0f %.0f %u %u %u %u\n", l.objectName.c_str(), l.objectPositionX,
                    l.objectPositionY, l.x, l.y, l.width, l.height);
      objects += line;
    }
    doom_objects = objects;
    if(state->screenBuffer)
    {
      auto const &bytes(*state->screenBuffer);
      std::vector<uint32_t> picture(size_t{ doom_width } * doom_height);
      for(size_t i{}; i < picture.size() && 3 * i + 2 < bytes.size(); ++i)
      {
        picture[i] = uint32_t{ bytes[3 * i] } << 16 | uint32_t{ bytes[3 * i + 1] } << 8 | bytes[3 * i + 2];
      }
      std::lock_guard<std::mutex> hold{ doom_lock };
      doom_queued.push_back(std::move(picture));
      while(doom_queued.size() > 70)
      {
        doom_queued.pop_front();
      }
    }
  }

  // The Doom engines this process started that are running (its children named vizdoom).
  std::vector<pid_t> doom_engines()
  {
    std::vector<pid_t> pids(512);
    int const bytes{ proc_listpids(PROC_PPID_ONLY, static_cast<uint32_t>(getpid()), pids.data(),
                                   static_cast<int>(pids.size() * sizeof(pid_t))) };
    pids.resize(bytes > 0 ? static_cast<size_t>(bytes) / sizeof(pid_t) : 0);
    std::vector<pid_t> engines;
    for(auto const pid : pids)
    {
      char name[64]{};
      if(pid > 0 && proc_name(pid, name, sizeof(name)) > 0 && std::strcmp(name, "vizdoom") == 0)
      {
        engines.push_back(pid);
      }
    }
    return engines;
  }

  // A watcher for Doom engine `engine`: a shell of its own process group (a signal to this
  // process's group doesn't reach it) that ends the engine once this process is gone. The
  // engine is a process of its own, which a closed game ends, but a killed jank process
  // leaves running (and it ignores SIGTERM). The watcher ends when the engine does.
  void doom_watch(pid_t engine)
  {
    std::string const script{ "(while kill -0 " + std::to_string(getpid()) + " 2>/dev/null; do kill -0 "
                              + std::to_string(engine) + " 2>/dev/null || exit 0; sleep 1; done; kill -9 "
                              + std::to_string(engine) + " 2>/dev/null) </dev/null >/dev/null 2>&1 &" };
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    char sh[]{ "/bin/sh" };
    char c[]{ "-c" };
    std::vector<char> text(script.begin(), script.end());
    text.push_back('\0');
    char *argv[]{ sh, c, text.data(), nullptr };
    pid_t pid{};
    if(posix_spawn(&pid, "/bin/sh", nullptr, &attr, argv, environ) == 0)
    {
      // The shell leaves the watcher running in the background and ends at once.
      waitpid(pid, nullptr, 0);
    }
    posix_spawnattr_destroy(&attr);
  }

  int copy_picture(std::mutex &lock, std::vector<uint32_t> const &picture, unsigned w, unsigned h, uint64_t shown,
                   uint32_t *out, int max, int *width, int *height, uint64_t *version)
  {
    std::lock_guard<std::mutex> hold{ lock };
    *width = static_cast<int>(w);
    *height = static_cast<int>(h);
    *version = shown;
    auto const n(std::min(picture.size(), static_cast<size_t>(std::max(max, 0))));
    std::copy_n(picture.begin(), n, out);
    return static_cast<int>(n);
  }
}

extern "C"
{
  // The NES.

  int play_nes_open(char const *core, char const *game, char *error, int size)
  {
    try
    {
      std::lock_guard<std::mutex> hold{ nes_lock };
      nes_now.reset();
      nes_now = std::make_unique<play::nes>(core);
      nes_now->load(game);
      nes_picture.clear();
      nes_queued.clear();
      nes_latest.clear();
      nes_shown = 0;
      return 0;
    }
    catch(std::exception const &e)
    {
      say(error, size, e.what());
      nes_now.reset();
      return -1;
    }
  }

  int play_nes_run(unsigned buttons, unsigned frames)
  {
    return play_nes_run2(buttons, 0, frames);
  }

  int play_nes_run2(unsigned buttons, unsigned buttons2, unsigned frames)
  {
    if(!nes_now)
    {
      return -1;
    }
    for(unsigned i{}; i < frames; ++i)
    {
      nes_now->run(buttons, 1, buttons2);
      std::lock_guard<std::mutex> hold{ nes_lock };
      nes_latest = nes_now->picture();
      nes_queued.push_back(nes_latest);
      while(nes_queued.size() > nes_queued_most)
      {
        nes_queued.pop_front();
      }
      nes_width = nes_now->width();
      nes_height = nes_now->height();
    }
    return 0;
  }

  long long play_nes_frames()
  {
    return nes_now ? static_cast<long long>(nes_now->frames) : -1;
  }

  int play_nes_ram(unsigned char *out, int max)
  {
    if(!nes_now)
    {
      return -1;
    }
    auto const n(std::min(nes_now->ram_size(), static_cast<size_t>(max)));
    std::memcpy(out, nes_now->ram(), n);
    return static_cast<int>(n);
  }

  // The cartridge's RAM at $6000 (a game's work RAM, or its battery-backed RAM).
  int play_nes_cartridge_ram(unsigned char *out, int max)
  {
    if(!nes_now)
    {
      return -1;
    }
    auto const data(static_cast<unsigned char const *>(nes_now->memory_data(RETRO_MEMORY_SAVE_RAM)));
    auto const size(nes_now->memory_size(RETRO_MEMORY_SAVE_RAM));
    if(!data)
    {
      return 0;
    }
    auto const n(std::min(size, static_cast<size_t>(max)));
    std::memcpy(out, data, n);
    return static_cast<int>(n);
  }

  int play_nes_picture(uint32_t *out, int max, int *width, int *height, uint64_t *version)
  {
    {
      // The next frame queued, when a 60th of a second has gone by since the last one.
      std::lock_guard<std::mutex> hold{ nes_lock };
      auto const now(std::chrono::steady_clock::now());
      if(!nes_queued.empty() && now - nes_popped >= std::chrono::microseconds{ 16667 })
      {
        nes_picture = std::move(nes_queued.front());
        nes_queued.pop_front();
        ++nes_shown;
        nes_popped = now;
      }
    }
    return copy_picture(nes_lock, nes_picture, nes_width, nes_height, nes_shown, out, max, width, height, version);
  }

  void play_nes_flush()
  {
    std::lock_guard<std::mutex> hold{ nes_lock };
    nes_queued.clear();
    nes_picture = nes_latest;
    ++nes_shown;
  }

  int play_nes_queued()
  {
    std::lock_guard<std::mutex> hold{ nes_lock };
    return static_cast<int>(nes_queued.size());
  }

  int play_nes_latest(uint32_t *out, int max, int *width, int *height)
  {
    uint64_t version{};
    return copy_picture(nes_lock, nes_latest, nes_width, nes_height, 0, out, max, width, height, &version);
  }

  void play_nes_show(uint32_t const *picture, int n, int width, int height)
  {
    std::lock_guard<std::mutex> hold{ nes_lock };
    nes_queued.clear();
    nes_latest.assign(picture, picture + std::max(n, 0));
    nes_picture = nes_latest;
    nes_width = static_cast<unsigned>(width);
    nes_height = static_cast<unsigned>(height);
    ++nes_shown;
  }

  int play_nes_save(unsigned char *out, int max)
  {
    if(!nes_now)
    {
      return -1;
    }
    auto const s(nes_now->save());
    if(!out)
    {
      return static_cast<int>(s.size());
    }
    auto const n(std::min(s.size(), static_cast<size_t>(max)));
    std::memcpy(out, s.data(), n);
    return static_cast<int>(n);
  }

  int play_nes_restore(unsigned char const *state, int size)
  {
    if(!nes_now)
    {
      return -1;
    }
    try
    {
      nes_now->restore({ state, state + size });
      return 0;
    }
    catch(std::exception const &)
    {
      return -1;
    }
  }

  // NetHack.

  int play_nethack_open(char const *library, char const *hackdir, char const *options, unsigned long seed,
                        char *error, int size)
  {
    std::lock_guard<std::mutex> hold{ nethack_lock };
    if(nethack_now)
    {
      nle_end(nethack_now);
      nethack_now = nullptr;
    }
    nethack_b = {};
    nethack_obs = {};
    nethack_wire();
    nethack_settings = {};
    std::snprintf(nethack_settings.hackdir, sizeof nethack_settings.hackdir, "%s", hackdir);
    std::snprintf(nethack_settings.options, sizeof nethack_settings.options, "%s", options);
    nethack_settings.spawn_monsters = 1;
    // The same seed, the same game: both of NetHack's generators, and the moon's phase.
    nethack_settings.initial_seeds.seeds[0] = seed;
    nethack_settings.initial_seeds.seeds[1] = seed ^ 0x9e3779b97f4a7c15ul;
    nethack_settings.initial_seeds.reseed = 0;
    nethack_settings.initial_seeds.use_init_seeds = true;
    nethack_settings.initial_seeds.lgen_seed = seed;
    nethack_settings.initial_seeds.use_lgen_seed = true;
    nethack_settings.fix_moon_phase = true;
    nethack_settings.time_seed = seed;
    nethack_settings.time_seed_is_set = true;
    nethack_now = nle_start(library, &nethack_obs, nullptr, &nethack_settings);
    if(!nethack_now)
    {
      say(error, size, "NetHack didn't start");
      return -1;
    }
    nethack_steps = 0;
    return 0;
  }

  // One key; whether the game has ended.
  int play_nethack_step(int key)
  {
    std::lock_guard<std::mutex> hold{ nethack_lock };
    if(!nethack_now)
    {
      return -1;
    }
    nethack_obs.action = key;
    nethack_now = nle_step(nethack_now, &nethack_obs);
    ++nethack_steps;
    return nethack_obs.done;
  }

  // The terminal: 24 rows of 80 characters, their colours (0 to 15), the cursor.
  int play_nethack_screen(char *chars, signed char *colors, int *cursor_row, int *cursor_col, uint64_t *version)
  {
    std::lock_guard<std::mutex> hold{ nethack_lock };
    std::memcpy(chars, nethack_b.tty_chars, sizeof nethack_b.tty_chars);
    std::memcpy(colors, nethack_b.tty_colors, sizeof nethack_b.tty_colors);
    *cursor_row = nethack_b.tty_cursor[0];
    *cursor_col = nethack_b.tty_cursor[1];
    *version = nethack_steps;
    return nethack_now ? 0 : -1;
  }

  // The bottom lines' numbers (NLE_BL_*), the last message, whether in a normal game (not a
  // menu or a question), done.
  int play_nethack_status(long *stats, char *message, int *in_normal_game, int *done)
  {
    std::lock_guard<std::mutex> hold{ nethack_lock };
    std::memcpy(stats, nethack_b.blstats, sizeof nethack_b.blstats);
    std::memcpy(message, nethack_b.message, sizeof nethack_b.message);
    message[NLE_MESSAGE_SIZE - 1] = 0;
    *in_normal_game = nethack_obs.in_normal_game;
    *done = nethack_obs.done;
    return nethack_now ? 0 : -1;
  }

  // The inventory, a line an item: "a - a +1 long sword (weapon in hand)".
  int play_nethack_inventory(char *out, int max)
  {
    std::lock_guard<std::mutex> hold{ nethack_lock };
    std::string all;
    for(int i{}; i < NLE_INVENTORY_SIZE; ++i)
    {
      auto const letter(nethack_b.inv_letters[i]);
      if(!letter)
      {
        continue;
      }
      std::string const item(reinterpret_cast<char const *>(nethack_b.inv_strs + i * NLE_INVENTORY_STR_LENGTH),
                             strnlen(reinterpret_cast<char const *>(nethack_b.inv_strs + i * NLE_INVENTORY_STR_LENGTH),
                                     NLE_INVENTORY_STR_LENGTH));
      all += std::string(1, static_cast<char>(letter)) + " - " + item + "\n";
    }
    std::snprintf(out, static_cast<size_t>(max), "%s", all.c_str());
    return static_cast<int>(all.size());
  }

  void play_nethack_close()
  {
    std::lock_guard<std::mutex> hold{ nethack_lock };
    if(nethack_now)
    {
      nle_end(nethack_now);
      nethack_now = nullptr;
    }
  }

  // Doom.

  int play_doom_open(char const *engine, char const *wad, char const *map, unsigned seed, int width, char *error,
                     int size)
  {
    try
    {
      if(doom_now)
      {
        doom_now->close();
        doom_now.reset();
      }
      auto const before(doom_engines());
      auto game(std::make_unique<vizdoom::DoomGame>());
      game->setViZDoomPath(engine);
      game->setDoomGamePath(wad);
      game->setDoomMap(map);
      game->setScreenResolution(width >= 640 ? vizdoom::RES_640X480 : vizdoom::RES_320X240);
      game->setScreenFormat(vizdoom::RGB24);
      game->setWindowVisible(false);
      game->setSoundEnabled(false);
      game->setLabelsBufferEnabled(true);
      game->setSectorsInfoEnabled(true);
      game->setRenderHud(true);
      game->setAvailableButtons(doom_buttons);
      game->setAvailableGameVariables(doom_variables);
      game->setEpisodeTimeout(0);
      game->setSeed(seed);
      game->setMode(vizdoom::PLAYER);
      game->init();
      game->newEpisode();
      for(auto const pid : doom_engines())
      {
        if(std::find(before.begin(), before.end(), pid) == before.end())
        {
          doom_watch(pid);
        }
      }
      doom_width = game->getScreenWidth();
      doom_height = game->getScreenHeight();
      doom_now = std::move(game);
      doom_shown = 0;
      {
        std::lock_guard<std::mutex> hold{ doom_lock };
        doom_queued.clear();
      }
      doom_take();
      return 0;
    }
    catch(std::exception const &e)
    {
      say(error, size, e.what());
      doom_now.reset();
      return -1;
    }
  }

  // The buttons held (a bit each, in doom_buttons' order: forward, back, turn left, turn
  // right, attack, use, strafe left, strafe right) for `tics`; the reward. -1e9 when the
  // episode had ended.
  double play_doom_act(unsigned buttons, int tics)
  {
    if(!doom_now || doom_now->isEpisodeFinished())
    {
      return -1e9;
    }
    std::vector<double> held(doom_buttons.size());
    for(size_t i{}; i < held.size(); ++i)
    {
      held[i] = (buttons >> i) & 1u ? 1.0 : 0.0;
    }
    try
    {
      // A tic at a time (the same tics as all at once), each one's picture queued.
      int const n{ std::max(tics, 1) };
      double reward{};
      for(int i{}; i < n && !doom_now->isEpisodeFinished(); ++i)
      {
        reward += doom_now->makeAction(held, 1);
        if(!doom_now->isEpisodeFinished())
        {
          doom_take(i == n - 1);
        }
      }
      return reward;
    }
    catch(std::exception const &)
    {
      return -1e9;
    }
  }

  int play_doom_finished()
  {
    return !doom_now || doom_now->isEpisodeFinished() ? 1 : 0;
  }

  // health armor ammo x y angle kills items dead, the tic; and the objects in view, a line
  // each: "name x y screen-x screen-y screen-width screen-height".
  int play_doom_state(double *variables, int max, int *tic, char *objects, int size)
  {
    if(!doom_now)
    {
      return -1;
    }
    auto const n(std::min(doom_vars.size(), static_cast<size_t>(max)));
    std::copy_n(doom_vars.begin(), n, variables);
    *tic = doom_tic;
    std::snprintf(objects, static_cast<size_t>(size), "%s", doom_objects.c_str());
    return static_cast<int>(n);
  }

  // How far the player can walk in each of doom_ray_angles' directions: angle, distance and
  // what ends it (doom_rays' kinds), three numbers a direction; the count of directions.
  int play_doom_rays(double *out, int max)
  {
    int n{};
    for(size_t i{}; i < doom_rays.size() && 3 * (n + 1) <= max; ++i, ++n)
    {
      out[3 * n] = doom_ray_angles[i];
      out[3 * n + 1] = doom_rays[i].first;
      out[3 * n + 2] = doom_rays[i].second;
    }
    return n;
  }

  int play_doom_picture(uint32_t *out, int max, int *width, int *height, uint64_t *version)
  {
    {
      std::lock_guard<std::mutex> hold{ doom_lock };
      auto const now(std::chrono::steady_clock::now());
      if(!doom_queued.empty() && now - doom_popped >= std::chrono::microseconds{ 28571 })
      {
        doom_picture = std::move(doom_queued.front());
        doom_queued.pop_front();
        ++doom_shown;
        doom_popped = now;
      }
    }
    return copy_picture(doom_lock, doom_picture, doom_width, doom_height, doom_shown, out, max, width, height, version);
  }

  void play_doom_close()
  {
    if(doom_now)
    {
      doom_now->close();
      doom_now.reset();
    }
  }
}
