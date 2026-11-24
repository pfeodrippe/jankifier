// SPDX-License-Identifier: MIT
// An NES emulator in the process: a libretro core (fceumm, built in vendor/) loaded with
// dlopen, a game loaded, frames run one at a time with the controller's buttons given, and
// the console's RAM, picture and saved state read back. One emulator a process (a libretro
// core is a set of globals).
//
//   play::nes n{ "vendor/libretro-fceumm/fceumm_libretro.dylib" };
//   n.load("game.nes");
//   n.run(play::right | play::a, 4);         // 4 frames with right and A held
//   uint8_t x{ n.ram()[0x86] };              // the 2 KiB of RAM
//   auto s(n.save());  n.restore(s);         // the whole console, to go back
#pragma once

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

#include <libretro.h>

namespace play
{
  // The controller's buttons, to combine with |.
  enum button : unsigned
  {
    b = 1u << RETRO_DEVICE_ID_JOYPAD_B,
    select = 1u << RETRO_DEVICE_ID_JOYPAD_SELECT,
    start = 1u << RETRO_DEVICE_ID_JOYPAD_START,
    up = 1u << RETRO_DEVICE_ID_JOYPAD_UP,
    down = 1u << RETRO_DEVICE_ID_JOYPAD_DOWN,
    left = 1u << RETRO_DEVICE_ID_JOYPAD_LEFT,
    right = 1u << RETRO_DEVICE_ID_JOYPAD_RIGHT,
    a = 1u << RETRO_DEVICE_ID_JOYPAD_A,
  };

  namespace detail
  {
    // What the core's callbacks see: the one emulator of the process.
    struct frontend
    {
      // The two controllers' buttons (port 0 and port 1).
      unsigned buttons{}, buttons2{};
      std::vector<uint32_t> picture; // XRGB8888
      unsigned width{}, height{};
      std::string directory{ "." };
      retro_pixel_format format{ RETRO_PIXEL_FORMAT_0RGB1555 };
    };

    inline frontend &the()
    {
      static frontend f;
      return f;
    }

    inline void log(retro_log_level level, char const *fmt, ...)
    {
      if(level < RETRO_LOG_WARN)
      {
        return;
      }
      va_list args;
      va_start(args, fmt);
      std::vfprintf(stderr, fmt, args);
      va_end(args);
    }

    inline bool environment(unsigned cmd, void *data)
    {
      auto &f(the());
      switch(cmd)
      {
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
          f.format = *static_cast<retro_pixel_format const *>(data);
          return f.format == RETRO_PIXEL_FORMAT_XRGB8888 || f.format == RETRO_PIXEL_FORMAT_RGB565
                 || f.format == RETRO_PIXEL_FORMAT_0RGB1555;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
          *static_cast<char const **>(data) = f.directory.c_str();
          return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
          static_cast<retro_log_callback *>(data)->log = log;
          return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
          *static_cast<bool *>(data) = true;
          return true;
        default:
          return false;
      }
    }

    inline uint32_t rgb(retro_pixel_format format, uint16_t p)
    {
      if(format == RETRO_PIXEL_FORMAT_RGB565)
      {
        uint32_t r{ (p >> 11) & 31u }, g{ (p >> 5) & 63u }, b{ p & 31u };
        return (r * 255 / 31) << 16 | (g * 255 / 63) << 8 | (b * 255 / 31);
      }
      uint32_t r{ (p >> 10) & 31u }, g{ (p >> 5) & 31u }, b{ p & 31u };
      return (r * 255 / 31) << 16 | (g * 255 / 31) << 8 | (b * 255 / 31);
    }

    inline void video(void const *data, unsigned width, unsigned height, size_t pitch)
    {
      auto &f(the());
      if(!data)
      {
        return; // the same frame again
      }
      f.width = width;
      f.height = height;
      f.picture.resize(size_t{ width } * height);
      for(unsigned y{}; y < height; ++y)
      {
        auto const row(static_cast<uint8_t const *>(data) + y * pitch);
        for(unsigned x{}; x < width; ++x)
        {
          f.picture[size_t{ y } * width + x]
            = f.format == RETRO_PIXEL_FORMAT_XRGB8888
                ? reinterpret_cast<uint32_t const *>(row)[x] & 0xffffffu
                : rgb(f.format, reinterpret_cast<uint16_t const *>(row)[x]);
        }
      }
    }

    inline void audio(int16_t, int16_t)
    {
    }

    inline size_t audio_batch(int16_t const *, size_t frames)
    {
      return frames;
    }

    inline void input_poll()
    {
    }

    inline int16_t input_state(unsigned port, unsigned device, unsigned, unsigned id)
    {
      if(port > 1 || device != RETRO_DEVICE_JOYPAD)
      {
        return 0;
      }
      unsigned const held{ port == 0 ? the().buttons : the().buttons2 };
      if(id == RETRO_DEVICE_ID_JOYPAD_MASK)
      {
        return static_cast<int16_t>(held);
      }
      return (held >> id) & 1u;
    }
  }

  struct nes
  {
    void *library{};
    void (*init)(){};
    void (*deinit)(){};
    void (*set_environment)(retro_environment_t){};
    void (*set_video_refresh)(retro_video_refresh_t){};
    void (*set_audio_sample)(retro_audio_sample_t){};
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t){};
    void (*set_input_poll)(retro_input_poll_t){};
    void (*set_input_state)(retro_input_state_t){};
    void (*set_controller_port_device)(unsigned, unsigned){};
    bool (*load_game)(retro_game_info const *){};
    void (*unload_game)(){};
    void (*run_frame)(){};
    void (*reset_console)(){};
    size_t (*serialize_size)(){};
    bool (*serialize)(void *, size_t){};
    bool (*unserialize)(void const *, size_t){};
    void *(*memory_data)(unsigned){};
    size_t (*memory_size)(unsigned){};
    std::vector<uint8_t> game;
    bool loaded{};
    uint64_t frames{};

    template <typename F>
    void find(F &f, char const *name)
    {
      f = reinterpret_cast<F>(dlsym(library, name));
      if(!f)
      {
        throw std::runtime_error(std::string{ "the core lacks " } + name);
      }
    }

    explicit nes(std::string const &core)
    {
      library = dlopen(core.c_str(), RTLD_NOW | RTLD_LOCAL);
      if(!library)
      {
        throw std::runtime_error(std::string{ "the core didn't load: " } + dlerror());
      }
      find(init, "retro_init");
      find(deinit, "retro_deinit");
      find(set_environment, "retro_set_environment");
      find(set_video_refresh, "retro_set_video_refresh");
      find(set_audio_sample, "retro_set_audio_sample");
      find(set_audio_sample_batch, "retro_set_audio_sample_batch");
      find(set_input_poll, "retro_set_input_poll");
      find(set_input_state, "retro_set_input_state");
      find(set_controller_port_device, "retro_set_controller_port_device");
      find(load_game, "retro_load_game");
      find(unload_game, "retro_unload_game");
      find(run_frame, "retro_run");
      find(reset_console, "retro_reset");
      find(serialize_size, "retro_serialize_size");
      find(serialize, "retro_serialize");
      find(unserialize, "retro_unserialize");
      find(memory_data, "retro_get_memory_data");
      find(memory_size, "retro_get_memory_size");
      set_environment(detail::environment);
      init();
      set_video_refresh(detail::video);
      set_audio_sample(detail::audio);
      set_audio_sample_batch(detail::audio_batch);
      set_input_poll(detail::input_poll);
      set_input_state(detail::input_state);
    }

    nes(nes const &) = delete;
    nes &operator=(nes const &) = delete;

    ~nes()
    {
      if(loaded)
      {
        unload_game();
      }
      deinit();
      dlclose(library);
    }

    // The game in the iNES file at `path`.
    void load(std::string const &path)
    {
      std::ifstream in{ path, std::ios::binary };
      if(!in)
      {
        throw std::runtime_error("no game at " + path);
      }
      game.assign(std::istreambuf_iterator<char>{ in }, std::istreambuf_iterator<char>{});
      retro_game_info info{ path.c_str(), game.data(), game.size(), nullptr };
      if(loaded)
      {
        unload_game();
      }
      if(!load_game(&info))
      {
        throw std::runtime_error("the core didn't take the game at " + path);
      }
      set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
      set_controller_port_device(1, RETRO_DEVICE_JOYPAD);
      loaded = true;
      frames = 0;
    }

    // `n` frames with `buttons` held on the first controller (and `buttons2` on the
    // second).
    void run(unsigned buttons, unsigned n = 1, unsigned buttons2 = 0)
    {
      detail::the().buttons = buttons;
      detail::the().buttons2 = buttons2;
      for(unsigned i{}; i < n; ++i)
      {
        run_frame();
        ++frames;
      }
    }

    void reset()
    {
      reset_console();
    }

    // The console's 2 KiB of RAM.
    uint8_t *ram() const
    {
      return static_cast<uint8_t *>(memory_data(RETRO_MEMORY_SYSTEM_RAM));
    }

    size_t ram_size() const
    {
      return memory_size(RETRO_MEMORY_SYSTEM_RAM);
    }

    // The last picture, as 0xRRGGBB pixels, row after row.
    std::vector<uint32_t> const &picture() const
    {
      return detail::the().picture;
    }

    unsigned width() const
    {
      return detail::the().width;
    }

    unsigned height() const
    {
      return detail::the().height;
    }

    // The whole console, and back to it.
    std::vector<uint8_t> save() const
    {
      std::vector<uint8_t> s(serialize_size());
      if(!serialize(s.data(), s.size()))
      {
        throw std::runtime_error("the core didn't save its state");
      }
      return s;
    }

    void restore(std::vector<uint8_t> const &s)
    {
      if(!unserialize(s.data(), s.size()))
      {
        throw std::runtime_error("the core didn't restore the state");
      }
    }
  };
}
