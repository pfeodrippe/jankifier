// SPDX-License-Identifier: MIT
// The games for jank: play.h's C calls with jank values in and out, and their pictures drawn
// in a card (on the window's thread, inside a card's draw function): an NES's or Doom's
// picture as a texture, NetHack's terminal as coloured text.
#pragma once

#include <play/play.h>

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <unistd.h>
#include <string>
#include <string_view>
#include <vector>

#include <OpenGL/gl.h>
#include <imgui.h>
#include <cards/cards.hpp>

#include <jank/runtime/context.hpp>
#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>
#include <jank/runtime/core/seq.hpp>
#include <jank/runtime/obj/keyword.hpp>
#include <jank/runtime/obj/persistent_array_map.hpp>
#include <jank/runtime/obj/persistent_string.hpp>
#include <jank/runtime/obj/persistent_vector.hpp>

namespace play
{
  namespace rt = ::jank::runtime;
  using rt::object_ref;

  inline std::string to_std(object_ref const o)
  {
    auto const s{ rt::to_string(o) };
    return { s.data(), s.size() };
  }

  inline object_ref str(std::string_view const s)
  {
    return rt::make_box<rt::obj::persistent_string>(jtl::immutable_string{ s.data(), s.size() });
  }

  inline object_ref kw(std::string_view const s)
  {
    return rt::__rt_ctx->intern_keyword(jtl::immutable_string{ s.data(), s.size() }).expect_ok();
  }

  inline object_ref num(double const d)
  {
    return rt::make_box(d);
  }

  inline object_ref integer(int64_t const i)
  {
    return rt::make_box(i);
  }

  inline int64_t to_int(object_ref const o)
  {
    return static_cast<int64_t>(rt::to_real(o));
  }

  inline object_ref bytes(unsigned char const *data, int n)
  {
    object_ref v{ rt::obj::persistent_vector::empty() };
    for(int i{}; i < n; ++i)
    {
      v = rt::conj(v, integer(data[i]));
    }
    return v;
  }

  // Angles and distances, for jank code that needs them.
  inline object_ref atan2(object_ref const y, object_ref const x)
  {
    return num(std::atan2(rt::to_real(y), rt::to_real(x)));
  }

  inline object_ref sqrt(object_ref const x)
  {
    return num(std::sqrt(rt::to_real(x)));
  }

  inline object_ref cos(object_ref const x)
  {
    return num(std::cos(rt::to_real(x)));
  }

  inline object_ref sin(object_ref const x)
  {
    return num(std::sin(rt::to_real(x)));
  }

  inline object_ref cwd()
  {
    return str(std::filesystem::current_path().string());
  }

  // nil, or what went wrong.
  inline object_ref said(int code, char const *error)
  {
    return code == 0 ? rt::jank_nil : str(error);
  }

  // The NES.

  inline object_ref nes_open(object_ref const core, object_ref const game)
  {
    char error[1024]{};
    return said(play_nes_open(to_std(core).c_str(), to_std(game).c_str(), error, sizeof error), error);
  }

  inline object_ref nes_run(object_ref const buttons, object_ref const frames)
  {
    return integer(play_nes_run(static_cast<unsigned>(to_int(buttons)), static_cast<unsigned>(to_int(frames))));
  }

  inline object_ref nes_run2(object_ref const buttons, object_ref const buttons2, object_ref const frames)
  {
    return integer(play_nes_run2(static_cast<unsigned>(to_int(buttons)), static_cast<unsigned>(to_int(buttons2)),
                                 static_cast<unsigned>(to_int(frames))));
  }

  inline object_ref nes_frames()
  {
    return integer(play_nes_frames());
  }

  // The console's 2 KiB of RAM, or the cartridge's from $6000, as a vector of bytes.
  inline object_ref nes_ram()
  {
    unsigned char ram[2048];
    return bytes(ram, play_nes_ram(ram, sizeof ram));
  }

  inline object_ref nes_cartridge_ram()
  {
    std::vector<unsigned char> ram(32768);
    return bytes(ram.data(), play_nes_cartridge_ram(ram.data(), static_cast<int>(ram.size())));
  }

  // A saved state is kept here, by a number (jank keeps the number), with the picture the
  // console showed then (restored with it: a restore shows it at once).
  struct nes_state
  {
    std::vector<unsigned char> bytes;
    std::vector<uint32_t> picture;
    int width{}, height{};
  };

  inline std::vector<nes_state> &nes_states()
  {
    static std::vector<nes_state> states;
    return states;
  }

  inline object_ref nes_save()
  {
    int const size(play_nes_save(nullptr, 0));
    if(size <= 0)
    {
      return rt::jank_nil;
    }
    nes_state s;
    s.bytes.resize(static_cast<size_t>(size));
    play_nes_save(s.bytes.data(), size);
    s.picture.resize(640 * 480);
    int const n(play_nes_latest(s.picture.data(), static_cast<int>(s.picture.size()), &s.width, &s.height));
    s.picture.resize(static_cast<size_t>(std::max(n, 0)));
    nes_states().push_back(std::move(s));
    return integer(static_cast<int64_t>(nes_states().size() - 1));
  }

  inline object_ref nes_queued()
  {
    return integer(play_nes_queued());
  }

  inline object_ref nes_flush()
  {
    play_nes_flush();
    return rt::jank_nil;
  }

  inline object_ref nes_restore(object_ref const which)
  {
    auto const i(static_cast<size_t>(to_int(which)));
    if(i >= nes_states().size())
    {
      return integer(-1);
    }
    auto const &s(nes_states()[i]);
    int const r(play_nes_restore(s.bytes.data(), static_cast<int>(s.bytes.size())));
    if(r == 0 && !s.picture.empty())
    {
      play_nes_show(s.picture.data(), static_cast<int>(s.picture.size()), s.width, s.height);
    }
    return integer(r);
  }

  // NetHack.

  // A directory for NetHack's files made anew at `dir` (its data `nhdat` linked, the files
  // it writes empty), and the player's name, NetHack's USER, not the user's: `dir`.
  inline object_ref nethack_prepare(object_ref const dir, object_ref const nhdat)
  {
    namespace fs = std::filesystem;
    fs::path const d{ to_std(dir) };
    std::error_code ignored;
    fs::remove_all(d, ignored);
    fs::create_directories(d / "save");
    fs::create_symlink(to_std(nhdat), d / "nhdat", ignored);
    for(char const *f : { "perm", "record", "logfile", "xlogfile" })
    {
      std::ofstream{ d / f };
    }
    ::setenv("USER", "agent", 1);
    return str(d.string() + "/");
  }

  inline object_ref nethack_open(object_ref const library, object_ref const hackdir, object_ref const options,
                                 object_ref const seed)
  {
    char error[1024]{};
    return said(play_nethack_open(to_std(library).c_str(), to_std(hackdir).c_str(), to_std(options).c_str(),
                                  static_cast<unsigned long>(to_int(seed)), error, sizeof error),
                error);
  }

  // A key; whether the game has ended.
  inline object_ref nethack_step(object_ref const key)
  {
    return rt::make_box(play_nethack_step(static_cast<int>(to_int(key))) == 1);
  }

  // {:screen [24 lines] :cursor [row col] :stats [27 numbers] :message "..." :normal bool
  //  :done bool :inventory "a - ...\n..."}
  inline object_ref nethack_state()
  {
    char chars[24 * 80];
    signed char colors[24 * 80];
    int row{}, col{};
    uint64_t version{};
    play_nethack_screen(chars, colors, &row, &col, &version);
    object_ref screen{ rt::obj::persistent_vector::empty() };
    for(int r{}; r < 24; ++r)
    {
      std::string line(chars + r * 80, 80);
      for(auto &c : line)
      {
        if(c == 0)
        {
          c = ' ';
        }
      }
      screen = rt::conj(screen, str(line));
    }
    long stats[27]{};
    char message[256]{};
    int normal{}, done{};
    play_nethack_status(stats, message, &normal, &done);
    object_ref numbers{ rt::obj::persistent_vector::empty() };
    for(long const s : stats)
    {
      numbers = rt::conj(numbers, integer(s));
    }
    std::vector<char> inventory(55 * 90);
    play_nethack_inventory(inventory.data(), static_cast<int>(inventory.size()));
    object_ref m{ rt::obj::persistent_array_map::empty() };
    m = rt::assoc(m, kw("screen"), screen);
    m = rt::assoc(m, kw("cursor"), rt::conj(rt::conj(rt::obj::persistent_vector::empty(), integer(row)), integer(col)));
    m = rt::assoc(m, kw("stats"), numbers);
    m = rt::assoc(m, kw("message"), str(message));
    m = rt::assoc(m, kw("normal"), rt::make_box(normal != 0));
    m = rt::assoc(m, kw("done"), rt::make_box(done != 0));
    m = rt::assoc(m, kw("inventory"), str(inventory.data()));
    return m;
  }

  inline object_ref nethack_close()
  {
    play_nethack_close();
    return rt::jank_nil;
  }

  // Doom.

  inline object_ref doom_open(object_ref const engine, object_ref const wad, object_ref const map,
                              object_ref const seed, object_ref const width)
  {
    char error[1024]{};
    return said(play_doom_open(to_std(engine).c_str(), to_std(wad).c_str(), to_std(map).c_str(),
                               static_cast<unsigned>(to_int(seed)), static_cast<int>(to_int(width)), error,
                               sizeof error),
                error);
  }

  inline object_ref doom_act(object_ref const buttons, object_ref const tics)
  {
    return num(play_doom_act(static_cast<unsigned>(to_int(buttons)), static_cast<int>(to_int(tics))));
  }

  inline object_ref doom_finished()
  {
    return rt::make_box(play_doom_finished() == 1);
  }

  // {:tic :health :armor :ammo :x :y :angle :kills :items :dead :objects [{:name :x :y :box [x y w h]}]}
  inline object_ref doom_state()
  {
    double v[16]{};
    int tic{};
    std::vector<char> objects(16384);
    int const n(play_doom_state(v, 16, &tic, objects.data(), static_cast<int>(objects.size())));
    object_ref m{ rt::obj::persistent_array_map::empty() };
    if(n < 0)
    {
      return rt::jank_nil;
    }
    char const *names[]{ "health", "armor", "ammo", "x", "y", "angle", "kills", "items", "dead" };
    m = rt::assoc(m, kw("tic"), integer(tic));
    for(int i{}; i < n && i < 9; ++i)
    {
      m = rt::assoc(m, kw(names[i]), num(v[i]));
    }
    object_ref list{ rt::obj::persistent_vector::empty() };
    std::string const all(objects.data());
    size_t start{};
    while(start < all.size())
    {
      auto const end(all.find('\n', start));
      std::string const line(all.substr(start, end == std::string::npos ? std::string::npos : end - start));
      start = end == std::string::npos ? all.size() : end + 1;
      char name[128]{};
      double x{}, y{};
      unsigned bx{}, by{}, bw{}, bh{};
      if(std::sscanf(line.c_str(), "%127s %lf %lf %u %u %u %u", name, &x, &y, &bx, &by, &bw, &bh) == 7)
      {
        object_ref o{ rt::obj::persistent_array_map::empty() };
        o = rt::assoc(o, kw("name"), str(name));
        o = rt::assoc(o, kw("x"), num(x));
        o = rt::assoc(o, kw("y"), num(y));
        object_ref box{ rt::obj::persistent_vector::empty() };
        for(unsigned const b : { bx, by, bw, bh })
        {
          box = rt::conj(box, integer(b));
        }
        o = rt::assoc(o, kw("box"), box);
        list = rt::conj(list, o);
      }
    }
    m = rt::assoc(m, kw("objects"), list);
    return m;
  }

  // How far the player can walk: [{:angle :distance :door} ...], angles to the left of
  // where it faces.
  inline object_ref doom_mark()
  {
    play_doom_mark();
    return rt::jank_nil;
  }

  // [{:x :y :floor :ceiling}]: the sectors that moved since doom_mark, with their changes.
  inline object_ref doom_moved()
  {
    std::vector<double> v(4 * 256);
    int const n(play_doom_moved(v.data(), static_cast<int>(v.size())));
    object_ref list{ rt::obj::persistent_vector::empty() };
    for(int i{}; i < n; ++i)
    {
      object_ref r{ rt::obj::persistent_array_map::empty() };
      r = rt::assoc(r, kw("x"), num(v[4 * i]));
      r = rt::assoc(r, kw("y"), num(v[4 * i + 1]));
      r = rt::assoc(r, kw("floor"), num(v[4 * i + 2]));
      r = rt::assoc(r, kw("ceiling"), num(v[4 * i + 3]));
      list = rt::conj(list, r);
    }
    return list;
  }

  inline object_ref doom_rays()
  {
    double v[64]{};
    int const n(play_doom_rays(v, 64));
    // Four numbers a ray: angle, distance, kind and the line's use special.
    object_ref list{ rt::obj::persistent_vector::empty() };
    for(int i{}; i < n; ++i)
    {
      object_ref r{ rt::obj::persistent_array_map::empty() };
      r = rt::assoc(r, kw("angle"), num(v[4 * i]));
      r = rt::assoc(r, kw("distance"), num(v[4 * i + 1]));
      // What ends the way: a door, the exit, or something else to use (a switch), and the
      // line's special (ZDoom's numbers).
      int const kind{ static_cast<int>(v[4 * i + 2]) };
      if(kind > 0)
      {
        r = rt::assoc(r, kw("ends"), kw(kind == 1 ? "door" : kind == 2 ? "exit" : "switch"));
        r = rt::assoc(r, kw("special"), integer(static_cast<int64_t>(v[4 * i + 3])));
      }
      list = rt::conj(list, r);
    }
    return list;
  }

  inline object_ref doom_close()
  {
    play_doom_close();
    return rt::jank_nil;
  }

  // Drawing, on the window's thread.

  struct texture
  {
    GLuint id{};
    int width{}, height{};
    uint64_t version{ ~uint64_t{} };
    std::vector<uint32_t> pixels;
    std::vector<unsigned char> rgba;
  };

  inline texture &texture_of(int which)
  {
    static texture textures[2];
    return textures[which == 0 ? 0 : 1];
  }

  // The game's picture (0 the NES, 1 Doom), uploaded when it changed, drawn in the rectangle
  // (x, y) to (x + w, y + h). Its width and height, for the card to keep the proportions.
  inline object_ref draw_picture(object_ref const which, object_ref const x, object_ref const y, object_ref const w,
                                 object_ref const h)
  {
    auto const game(static_cast<int>(to_int(which)));
    auto &t(texture_of(game));
    t.pixels.resize(640 * 480);
    int width{}, height{};
    uint64_t version{};
    int const n(game == 0 ? play_nes_picture(t.pixels.data(), static_cast<int>(t.pixels.size()), &width, &height,
                                             &version)
                          : play_doom_picture(t.pixels.data(), static_cast<int>(t.pixels.size()), &width, &height,
                                              &version));
    if(n <= 0 || width <= 0 || height <= 0)
    {
      return rt::jank_nil;
    }
    if(t.id == 0)
    {
      glGenTextures(1, &t.id);
    }
    if(version != t.version || width != t.width || height != t.height)
    {
      t.rgba.resize(static_cast<size_t>(width) * height * 4);
      for(int i{}; i < width * height && i < n; ++i)
      {
        auto const p(t.pixels[static_cast<size_t>(i)]);
        t.rgba[4 * i] = static_cast<unsigned char>(p >> 16);
        t.rgba[4 * i + 1] = static_cast<unsigned char>(p >> 8);
        t.rgba[4 * i + 2] = static_cast<unsigned char>(p);
        t.rgba[4 * i + 3] = 255;
      }
      glBindTexture(GL_TEXTURE_2D, t.id);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, t.rgba.data());
      glBindTexture(GL_TEXTURE_2D, 0);
      t.version = version;
      t.width = width;
      t.height = height;
    }
    auto const x0(static_cast<float>(rt::to_real(x))), y0(static_cast<float>(rt::to_real(y)));
    auto const x1(x0 + static_cast<float>(rt::to_real(w))), y1(y0 + static_cast<float>(rt::to_real(h)));
    ImGui::GetWindowDrawList()->AddImage(ImTextureRef(static_cast<ImTextureID>(t.id)), ImVec2(x0, y0), ImVec2(x1, y1));
    return rt::conj(rt::conj(rt::obj::persistent_vector::empty(), integer(width)), integer(height));
  }

  // NetHack's 16 terminal colours.
  inline ImU32 nethack_color(int c)
  {
    static ImU32 const colors[16]{
      IM_COL32(110, 110, 110, 255), IM_COL32(205, 49, 49, 255),   IM_COL32(13, 188, 121, 255),
      IM_COL32(229, 165, 16, 255),  IM_COL32(36, 114, 200, 255),  IM_COL32(188, 63, 188, 255),
      IM_COL32(17, 168, 205, 255),  IM_COL32(204, 204, 204, 255), IM_COL32(118, 118, 118, 255),
      IM_COL32(241, 76, 76, 255),   IM_COL32(35, 209, 139, 255),  IM_COL32(245, 245, 67, 255),
      IM_COL32(59, 142, 234, 255),  IM_COL32(214, 112, 214, 255), IM_COL32(41, 184, 219, 255),
      IM_COL32(242, 242, 242, 255)
    };
    return colors[c & 15];
  }

  // NetHack's terminal drawn in the rectangle at (x, y), `width` by `height`, on a dark
  // ground, its characters as large as fit.
  inline object_ref draw_nethack(object_ref const x, object_ref const y, object_ref const width,
                                 object_ref const height)
  {
    char chars[24 * 80];
    signed char colors[24 * 80];
    int row{}, col{};
    uint64_t version{};
    if(play_nethack_screen(chars, colors, &row, &col, &version) != 0)
    {
      return rt::jank_nil;
    }
    auto &s(cards::get());
    ImFont *const font(s.fonts[1]);
    float const x0(static_cast<float>(rt::to_real(x))), y0(static_cast<float>(rt::to_real(y)));
    float const w(static_cast<float>(rt::to_real(width))), h(static_cast<float>(rt::to_real(height)));
    float const at_size(s.sizes[1]);
    float const cell_at(font->CalcTextSizeA(at_size, 1e6f, 0.0f, "M").x);
    float const size(std::min(at_size * ((w - 8) / 80.0f) / cell_at, ((h - 8) / 24.0f) / 1.15f));
    float const cell(cell_at * size / at_size), line(size * 1.15f);
    auto *const list(ImGui::GetWindowDrawList());
    list->AddRectFilled(ImVec2(x0, y0), ImVec2(x0 + 8 + cell * 80, y0 + 8 + line * 24), IM_COL32(18, 18, 22, 255), 6.0f);
    for(int r{}; r < 24; ++r)
    {
      for(int c{}; c < 80; ++c)
      {
        char const ch(chars[r * 80 + c]);
        if(ch == 0 || ch == ' ')
        {
          continue;
        }
        char const one[2]{ ch, 0 };
        list->AddText(font, size, ImVec2(x0 + 4 + c * cell, y0 + 4 + r * line),
                      nethack_color(colors[r * 80 + c]), one);
      }
    }
    list->AddRect(ImVec2(x0 + 4 + col * cell, y0 + 4 + row * line),
                  ImVec2(x0 + 4 + (col + 1) * cell, y0 + 4 + (row + 1) * line), IM_COL32(255, 255, 255, 120));
    return rt::jank_nil;
  }
}
