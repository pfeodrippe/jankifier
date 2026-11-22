// SPDX-License-Identifier: MIT
// cards, the native side: one window (GLFW, Dear ImGui on OpenGL 2), its fonts, drawing
// primitives in points from the window's top left, the mouse, a frame saved as an image, and
// the frames recorded to a video (ffmpeg reading them from a pipe). What is drawn, and where,
// is jank's (cards.core): every argument here is a jank object, so jank calls these as they
// are. Adapted from determinismo's jank-viz (include/detviz.hpp).
#pragma once

#include <cfloat>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <GLFW/glfw3.h>
#if defined(__APPLE__)
/* The framebuffer object extension (GLFW's header leaves the extensions out). */
#  include <OpenGL/glext.h>
#endif
#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl2.h"

#include <jank/runtime/core.hpp>
#include <jank/runtime/core/make_box.hpp>
#include <jank/runtime/core/math.hpp>
#include <jank/runtime/core/seq.hpp>
#include <jank/runtime/core/to_string.hpp>
#include <jank/runtime/core/truthy.hpp>

namespace cards
{
  using obj = jank::runtime::object_ref;

  inline double num(obj const o)
  {
    return jank::runtime::to_real(o);
  }

  inline std::string str(obj const o)
  {
    auto const s(jank::runtime::to_string(o));
    return std::string(s.data(), s.size());
  }

  struct state
  {
    GLFWwindow *window{};
    /* Text sizes: 0 small, 1 normal, 2 large (mono); 3 normal, 4 large (serif); 5 normal mono,
     * bold. */
    ImFont *fonts[6]{};
    float sizes[6]{ 12.0f, 14.0f, 18.0f, 15.0f, 26.0f, 14.0f };
    FILE *recording{};
    std::vector<unsigned char> pixels;
    /* A recording's frames: drawn into a framebuffer of its own, the size asked, whatever the
     * display gave the window (a laptop's is shorter than 1080 points, and doubles pixels). */
    int frame_width{}, frame_height{};
    /* Pixels a point in a hidden window or a recording (2: as a Retina screen draws), and
     * whether glyphs are put on whole pixels. Set before `open`. */
    float frame_scale{ 1.0f };
    bool font_snap{};
    unsigned target{}, target_color{};
    std::chrono::steady_clock::time_point recording_start;
    std::chrono::steady_clock::time_point frame_next;
    long frames_written{};
    long frames_drawn{};
    /* The next frame also written here (a PPM image), then cleared. */
    std::string snapshot;
    unsigned background{ 0xfdf6d8 };
    /* A scripted mouse (pointer, press): its events, given to ImGui at the next frame's
     * start, on the main thread. */
    struct pointer_event
    {
      int kind{}; /* 0 moved, 1 pressed, 2 released, 3 gone, 4 the wheel turned (by y) */
      float x{}, y{};
    };
    std::mutex pointer_lock;
    std::vector<pointer_event> pointer_events;
    bool pointer_scripted{};
    /* The mouse's place was asked of GLFW, the window not being in front (frame_begin). */
    bool pointer_asked{};
    /* What is being drawn is under an overlay: the mouse isn't its (cover). */
    bool covered{};
  };

  inline state &get()
  {
    static state s;
    return s;
  }

  inline ImU32 color(obj const rgb, double const alpha)
  {
    auto const value(static_cast<unsigned>(num(rgb)));
    return IM_COL32((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff, static_cast<int>(alpha * 255.0));
  }

  /* The window: `hidden` renders without showing (a recording); `record` is the video's path
   * ("" for none), frames written at 30 a second of wall time, its first one's wall-clock time
   * (ms since the epoch) in `<record>.start`. */
  inline bool open(obj const width, obj const height, obj const hidden, obj const record, obj const title)
  {
    auto &s(get());
    if(s.window)
    {
      return true;
    }
    if(!glfwInit())
    {
      return false;
    }
    auto const path(str(record));
    glfwWindowHint(GLFW_VISIBLE, jank::runtime::truthy(hidden) ? GLFW_FALSE : GLFW_TRUE);
    s.window = glfwCreateWindow(static_cast<int>(num(width)), static_cast<int>(num(height)), str(title).c_str(), nullptr, nullptr);
    if(!s.window)
    {
      return false;
    }
    glfwMakeContextCurrent(s.window);
    glfwSwapInterval(1);
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    auto &io(ImGui::GetIO());
    io.IniFilename = nullptr;
    ImGui::StyleColorsLight();
    int window_width{}, frame_width{}, unused{};
    glfwGetWindowSize(s.window, &window_width, &unused);
    glfwGetFramebufferSize(s.window, &frame_width, &unused);
    /* A hidden window and a recording are drawn at one pixel a point, into a framebuffer of
     * their own. */
    bool const offscreen(jank::runtime::truthy(hidden) || !path.empty());
    auto const scale(offscreen ? s.frame_scale
                               : (window_width <= 0 ? 1.0f : static_cast<float>(frame_width) / static_cast<float>(window_width)));
    char const *mono("/System/Library/Fonts/Menlo.ttc");
    char const *serif("/System/Library/Fonts/Supplemental/Georgia.ttf");
    for(int i{}; i < 6; ++i)
    {
      ImFontConfig config;
      bool const is_mono(i < 3 || i == 5);
      /* Menlo's second face is its bold. stb_truetype draws thin, light strokes: the mono
       * ones a little darker. */
      config.FontNo = i == 5 ? 1 : 0;
      config.RasterizerMultiply = is_mono ? 1.25f : 1.0f;
      config.PixelSnapH = s.font_snap;
      s.fonts[i] = io.Fonts->AddFontFromFileTTF(is_mono ? mono : serif, s.sizes[i] * scale, &config);
      if(!s.fonts[i])
      {
        s.fonts[i] = io.Fonts->AddFontDefault();
      }
    }
    io.FontGlobalScale = 1.0f / scale;
    ImGui_ImplGlfw_InitForOpenGL(s.window, true);
    ImGui_ImplOpenGL2_Init();
    if(offscreen)
    {
      s.frame_width = static_cast<int>(num(width) * s.frame_scale);
      s.frame_height = static_cast<int>(num(height) * s.frame_scale);
      glGenTextures(1, &s.target_color);
      glBindTexture(GL_TEXTURE_2D, s.target_color);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB8, s.frame_width, s.frame_height, 0, GL_RGB, GL_UNSIGNED_BYTE, nullptr);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glBindTexture(GL_TEXTURE_2D, 0);
      glGenFramebuffersEXT(1, &s.target);
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, s.target);
      glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, s.target_color, 0);
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
      s.frame_next = std::chrono::steady_clock::now();
      s.pixels.resize(static_cast<size_t>(s.frame_width) * static_cast<size_t>(s.frame_height) * 3);
    }
    if(!path.empty())
    {
      char command[2048];
      std::snprintf(command, sizeof(command),
                    "ffmpeg -loglevel error -y -f rawvideo -pixel_format rgb24 -video_size %dx%d -framerate 30 -i - "
                    "-vf vflip -c:v libx264 -preset veryfast -crf 16 -pix_fmt yuv420p '%s'",
                    s.frame_width, s.frame_height, path.c_str());
      s.recording = popen(command, "w");
    }
    return true;
  }

  /* How a hidden window or a recording is drawn: `scale` pixels a point, glyphs on whole
   * pixels or not. Before `open`. */
  inline void set_rendering(obj const scale, obj const snap)
  {
    auto &s(get());
    s.frame_scale = static_cast<float>(num(scale));
    s.font_snap = jank::runtime::truthy(snap);
  }

  inline bool alive()
  {
    auto &s(get());
    return s.window && !glfwWindowShouldClose(s.window);
  }

  inline void stop()
  {
    auto &s(get());
    if(s.window)
    {
      glfwSetWindowShouldClose(s.window, GLFW_TRUE);
    }
  }

  inline double width()
  {
    return ImGui::GetIO().DisplaySize.x;
  }

  inline double height()
  {
    return ImGui::GetIO().DisplaySize.y;
  }

  /* Seconds since the window opened: what moves (a cursor's pulse) reads it. */
  inline double seconds()
  {
    return glfwGetTime();
  }

  inline void frame_begin(obj const background)
  {
    auto &s(get());
    s.background = static_cast<unsigned>(num(background));
    glfwPollEvents();
    ImGui_ImplOpenGL2_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    if(s.target)
    {
      ImGui::GetIO().DisplaySize = ImVec2(static_cast<float>(s.frame_width) / s.frame_scale,
                                          static_cast<float>(s.frame_height) / s.frame_scale);
      ImGui::GetIO().DisplayFramebufferScale = ImVec2(s.frame_scale, s.frame_scale);
    }
    /* A window behind another one (the editor just typed in) is told when the wheel turns
     * over it, but not where the mouse is: asked here, so that what is under it answers. */
    if(!s.target && !s.pointer_scripted)
    {
      bool const front(glfwGetWindowAttrib(s.window, GLFW_FOCUSED) != 0);
      if(!front && glfwGetWindowAttrib(s.window, GLFW_HOVERED) != 0)
      {
        double x{}, y{};
        glfwGetCursorPos(s.window, &x, &y);
        ImGui::GetIO().AddMousePosEvent(static_cast<float>(x), static_cast<float>(y));
        s.pointer_asked = true;
      }
      else if(s.pointer_asked)
      {
        if(!front)
        {
          ImGui::GetIO().AddMousePosEvent(-FLT_MAX, -FLT_MAX);
        }
        s.pointer_asked = false;
      }
    }
    {
      std::lock_guard<std::mutex> const lock(s.pointer_lock);
      auto &io(ImGui::GetIO());
      for(auto const &e : s.pointer_events)
      {
        switch(e.kind)
        {
          case 0:
            io.AddMousePosEvent(e.x, e.y);
            s.pointer_scripted = true;
            break;
          case 1:
            io.AddMouseButtonEvent(0, true);
            break;
          case 2:
            io.AddMouseButtonEvent(0, false);
            break;
          case 4:
            io.AddMouseWheelEvent(0.0f, e.y);
            break;
          case 5:
            io.AddKeyEvent(ImGuiKey_Escape, true);
            io.AddKeyEvent(ImGuiKey_Escape, false);
            break;
          default:
            io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
            s.pointer_scripted = false;
        }
      }
      s.pointer_events.clear();
    }
    ImGui::NewFrame();
    /* ImGui 1.92 rasterizes glyphs at the screen's density (2 on a Retina screen) only for
     * the font it calls current; every other font stays at 1, its glyphs drawn at half the
     * screen's pixels and stretched: blurred. All of ours drawn at the screen's density. */
    {
      auto const density(ImGui::GetMainViewport()->FramebufferScale.x);
      for(auto *const font : s.fonts)
      {
        if(font && density > 0.0f)
        {
          font->CurrentRasterizerDensity = density;
        }
      }
    }
    /* One window over everything, nothing of its own drawn: the primitives' canvas. */
    ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f));
    ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
    ImGui::Begin("canvas", nullptr,
                 ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoBackground
                   | ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
  }

  inline void frame_end()
  {
    auto &s(get());
    if(s.covered)
    {
      ImGui::EndDisabled();
      s.covered = false;
    }
    ImGui::End();
    ImGui::Render();
    int frame_width{ s.frame_width }, frame_height{ s.frame_height };
    if(s.target)
    {
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, s.target);
    }
    else
    {
      glfwGetFramebufferSize(s.window, &frame_width, &frame_height);
    }
    glViewport(0, 0, frame_width, frame_height);
    glClearColor(static_cast<float>((s.background >> 16) & 0xff) / 255.0f,
                 static_cast<float>((s.background >> 8) & 0xff) / 255.0f,
                 static_cast<float>(s.background & 0xff) / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());
    ++s.frames_drawn;
    bool const wanted(s.recording || !s.snapshot.empty());
    if(wanted)
    {
      s.pixels.resize(static_cast<size_t>(frame_width) * static_cast<size_t>(frame_height) * 3);
      glPixelStorei(GL_PACK_ALIGNMENT, 1);
      glReadPixels(0, 0, frame_width, frame_height, GL_RGB, GL_UNSIGNED_BYTE, s.pixels.data());
    }
    if(!s.snapshot.empty())
    {
      if(FILE *out{ std::fopen(s.snapshot.c_str(), "wb") })
      {
        std::fprintf(out, "P6\n%d %d\n255\n", frame_width, frame_height);
        for(int y{ frame_height - 1 }; y >= 0; --y)
        {
          std::fwrite(s.pixels.data() + static_cast<size_t>(y) * static_cast<size_t>(frame_width) * 3, 1, static_cast<size_t>(frame_width) * 3, out);
        }
        std::fclose(out);
      }
      s.snapshot.clear();
    }
    if(!s.target)
    {
      glfwSwapBuffers(s.window);
      return;
    }
    if(s.recording)
    {
      auto const now(std::chrono::steady_clock::now());
      if(s.frames_written == 0)
      {
        s.recording_start = now;
        /* The first frame's wall-clock time (ms since the epoch): what a video made of this
         * one and another recording is aligned by. */
        auto const epoch(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
        std::fprintf(stderr, "[cards] capture %lld\n", static_cast<long long>(epoch));
      }
      /* As many frames as the wall clock asks at 30 a second: one repeated when frames are slow. */
      auto const elapsed(std::chrono::duration<double>(now - s.recording_start).count());
      auto const due(static_cast<long>(elapsed * 30.0) + 1);
      while(s.frames_written < due)
      {
        std::fwrite(s.pixels.data(), 1, s.pixels.size(), s.recording);
        ++s.frames_written;
      }
    }
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    /* No display paces a framebuffer of its own: 60 frames a second by the clock. */
    s.frame_next += std::chrono::microseconds(16667);
    auto const now(std::chrono::steady_clock::now());
    if(s.frame_next < now)
    {
      s.frame_next = now;
    }
    std::this_thread::sleep_until(s.frame_next);
  }

  inline double frames()
  {
    return static_cast<double>(get().frames_drawn);
  }

  inline void snapshot(obj const path)
  {
    get().snapshot = str(path);
  }

  /* The mouse, in points, and how far its wheel turned this frame (up is positive). */
  inline double mouse_x()
  {
    return get().covered ? -FLT_MAX : ImGui::GetIO().MousePos.x;
  }

  inline double mouse_y()
  {
    return get().covered ? -FLT_MAX : ImGui::GetIO().MousePos.y;
  }

  inline double wheel()
  {
    return get().covered ? 0.0 : ImGui::GetIO().MouseWheel;
  }

  /* What is drawn from here on is under an overlay (or no longer): the mouse and ImGui's
   * widgets answer only to the overlay. */
  inline void cover(obj const on)
  {
    auto &s(get());
    bool const wanted(jank::runtime::truthy(on));
    if(wanted == s.covered)
    {
      return;
    }
    if(wanted)
    {
      ImGui::BeginDisabled(true);
    }
    else
    {
      ImGui::EndDisabled();
    }
    s.covered = wanted;
  }

  /* Whether Esc was pressed in this frame, and the scripted one. */
  inline bool escaped()
  {
    return !get().covered && ImGui::IsKeyPressed(ImGuiKey_Escape, false);
  }

  inline void escape()
  {
    auto &s(get());
    std::lock_guard<std::mutex> const lock(s.pointer_lock);
    s.pointer_events.push_back({ 5, 0.0f, 0.0f });
  }

  /* A scripted mouse, for a window nobody points at (hidden: a test, a video): moved to a
   * point, pressed and released there, or gone. A window in front takes the real mouse's
   * place again as it moves. */
  inline void pointer(obj const x, obj const y)
  {
    auto &s(get());
    std::lock_guard<std::mutex> const lock(s.pointer_lock);
    s.pointer_events.push_back({ 0, static_cast<float>(num(x)), static_cast<float>(num(y)) });
  }

  inline void press(obj const x, obj const y)
  {
    auto &s(get());
    std::lock_guard<std::mutex> const lock(s.pointer_lock);
    s.pointer_events.push_back({ 0, static_cast<float>(num(x)), static_cast<float>(num(y)) });
    s.pointer_events.push_back({ 1, 0.0f, 0.0f });
    s.pointer_events.push_back({ 2, 0.0f, 0.0f });
  }

  /* The scripted mouse's button pressed or let go where it is (dragging). */
  inline void button(obj const held)
  {
    auto &s(get());
    std::lock_guard<std::mutex> const lock(s.pointer_lock);
    s.pointer_events.push_back({ jank::runtime::truthy(held) ? 1 : 2, 0.0f, 0.0f });
  }

  inline void pointer_off()
  {
    auto &s(get());
    std::lock_guard<std::mutex> const lock(s.pointer_lock);
    s.pointer_events.push_back({ 3, 0.0f, 0.0f });
  }

  inline bool pointer_scripted()
  {
    return get().pointer_scripted;
  }

  /* The scripted mouse's wheel turned (up is positive), where the mouse is. */
  inline void turn(obj const amount)
  {
    auto &s(get());
    std::lock_guard<std::mutex> const lock(s.pointer_lock);
    s.pointer_events.push_back({ 4, 0.0f, static_cast<float>(num(amount)) });
  }

  /* Whether the mouse is in a rectangle, and whether it was clicked there: pressed and
   * released inside it, said in the frame of the release. For a draw function that makes
   * parts of its drawing answer the mouse. */
  inline bool inside(obj const x1, obj const y1, obj const x2, obj const y2)
  {
    if(get().covered)
    {
      return false;
    }
    auto const at(ImGui::GetIO().MousePos);
    return at.x >= num(x1) && at.x < num(x2) && at.y >= num(y1) && at.y < num(y2);
  }

  /* Whether the mouse's button is held down (for dragging). */
  inline bool down()
  {
    return !get().covered && ImGui::IsMouseDown(0);
  }

  inline bool clicked(obj const x1, obj const y1, obj const x2, obj const y2)
  {
    if(!ImGui::IsMouseReleased(0))
    {
      return false;
    }
    auto const pressed(ImGui::GetIO().MouseClickedPos[0]);
    return inside(x1, y1, x2, y2) && pressed.x >= num(x1) && pressed.x < num(x2) && pressed.y >= num(y1)
           && pressed.y < num(y2);
  }

  /* The scripted mouse drawn as an arrow, over everything: a hidden window has no cursor of
   * the system's to show where it is. */
  inline void pointer_draw()
  {
    if(!get().pointer_scripted)
    {
      return;
    }
    auto const at(ImGui::GetIO().MousePos);
    auto const list(ImGui::GetForegroundDrawList());
    ImVec2 const outline[7]{
      { at.x, at.y },                 { at.x, at.y + 17.0f },         { at.x + 4.5f, at.y + 13.0f },
      { at.x + 7.5f, at.y + 19.5f },  { at.x + 10.5f, at.y + 18.0f }, { at.x + 7.5f, at.y + 11.5f },
      { at.x + 12.5f, at.y + 11.5f },
    };
    auto const dark(IM_COL32(26, 26, 26, 255));
    list->AddTriangleFilled(outline[0], outline[1], outline[6], dark);
    list->AddQuadFilled(outline[2], outline[3], outline[4], outline[5], dark);
    list->AddPolyline(outline, 7, IM_COL32(255, 255, 255, 255), ImDrawFlags_Closed, 1.5f);
  }

  inline void close()
  {
    auto &s(get());
    if(s.recording)
    {
      pclose(s.recording);
      s.recording = nullptr;
    }
    if(s.window)
    {
      ImGui_ImplOpenGL2_Shutdown();
      ImGui_ImplGlfw_Shutdown();
      ImGui::DestroyContext();
      glfwDestroyWindow(s.window);
      glfwTerminate();
      s.window = nullptr;
    }
  }

  /* The process ended here, after `close` (its video whole: ffmpeg waited for), with no static
   * destructors: jank's own exit destroyed the JIT under the nREPL thread still compiling the
   * evaluation that asked the window to stop, an abort and a crash report at every take's end
   * (2026-11-15). */
  [[noreturn]] inline void quit()
  {
    std::fflush(nullptr);
    std::_Exit(0);
  }

  /* A line on stderr, written at once: what a script driving the REPL reads from the
   * process's log (cards.core/announce!). */
  inline void say(obj const what)
  {
    std::fprintf(stderr, "%s\n", str(what).c_str());
    std::fflush(stderr);
  }

  /* Where ImGui's own widgets go next (ImGui::Text, Button, ...), in points: a draw function
   * places them in its card with this. */
  inline void cursor(obj const x, obj const y)
  {
    ImGui::SetCursorScreenPos(ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))));
  }

  /* What is drawn until clip_end is cut to this rectangle. */
  inline void clip_begin(obj const x1, obj const y1, obj const x2, obj const y2)
  {
    ImGui::GetWindowDrawList()->PushClipRect(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                             ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))), true);
  }

  inline void clip_end()
  {
    ImGui::GetWindowDrawList()->PopClipRect();
  }

  inline int font_of(obj const size)
  {
    auto const index(static_cast<int>(num(size)));
    return index < 0 ? 0 : (index > 5 ? 5 : index);
  }

  inline void text(obj const x, obj const y, obj const rgb, obj const size, obj const what)
  {
    auto &s(get());
    auto const index(font_of(size));
    auto const said(str(what));
    ImGui::GetWindowDrawList()->AddText(s.fonts[index], s.sizes[index],
                                        ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))),
                                        color(rgb, 1.0), said.c_str());
  }

  inline double text_width(obj const size, obj const what)
  {
    auto &s(get());
    auto const index(font_of(size));
    auto const said(str(what));
    return s.fonts[index]->CalcTextSizeA(s.sizes[index], 100000.0f, 0.0f, said.c_str()).x;
  }

  /* How many bytes of `what` fit in `width` points at a size, whole characters (at least
   * one); -1 when all of it fits. A string is cut there, never inside a character. */
  inline double fit(obj const size, obj const what, obj const width)
  {
    auto &s(get());
    auto const index(font_of(size));
    auto const said(str(what));
    auto const begin(said.c_str());
    auto const end(begin + said.size());
    char const *rest{};
    s.fonts[index]->CalcTextSizeA(s.sizes[index], static_cast<float>(num(width)), 0.0f, begin, end, &rest);
    if(rest == nullptr || rest >= end)
    {
      return -1.0;
    }
    if(rest == begin)
    {
      ++rest;
      while(rest < end && (static_cast<unsigned char>(*rest) & 0xC0) == 0x80)
      {
        ++rest;
      }
    }
    return static_cast<double>(rest - begin);
  }

  /* `what` broken into lines of at most `width` points at a size, between words where it
   * can be (ImGui's own word wrap; a word wider than a line between its characters), at
   * most `limit` lines: the lines joined by newlines. A line's indentation is kept; the
   * spaces where a line is broken are not. */
  inline std::string wrap_words(obj const size, obj const what, obj const width, obj const limit)
  {
    auto &s(get());
    auto const index(font_of(size));
    auto *const font(s.fonts[index]);
    auto const px(s.sizes[index]);
    auto const wide(static_cast<float>(num(width)));
    auto const most(static_cast<long>(num(limit)));
    auto const text(str(what));
    char const *at(text.c_str());
    char const *const end(at + text.size());
    std::string out;
    long lines{};
    auto const emit([&](char const *from, char const *to) {
      if(lines > 0)
      {
        out.push_back('\n');
      }
      out.append(from, static_cast<size_t>(to - from));
      ++lines;
    });
    while(lines < most)
    {
      auto const newline(static_cast<char const *>(std::memchr(at, '\n', static_cast<size_t>(end - at))));
      char const *const line_end(newline ? newline : end);
      if(at == line_end)
      {
        emit(at, at);
      }
      char const *q(at);
      while(q < line_end && lines < most)
      {
        char const *cut(font->CalcWordWrapPosition(px, q, line_end, wide));
        if(cut <= q)
        {
          /* Not even a character fits: one, whole. */
          cut = q + 1;
          while(cut < line_end && (static_cast<unsigned char>(*cut) & 0xC0) == 0x80)
          {
            ++cut;
          }
        }
        emit(q, cut);
        q = cut;
        while(q < line_end && *q == ' ')
        {
          ++q;
        }
      }
      if(!newline)
      {
        break;
      }
      at = newline + 1;
    }
    return out;
  }

  inline void line(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const thickness)
  {
    ImGui::GetWindowDrawList()->AddLine(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                        ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                        color(rgb, 1.0), static_cast<float>(num(thickness)));
  }

  /* From (x1, y1) level, down (or up) to (x2, y2) level. */
  inline void curve(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const thickness)
  {
    auto const ax(static_cast<float>(num(x1))), ay(static_cast<float>(num(y1)));
    auto const bx(static_cast<float>(num(x2))), by(static_cast<float>(num(y2)));
    auto const mid((ax + bx) / 2.0f);
    ImGui::GetWindowDrawList()->AddBezierCubic(ImVec2(ax, ay), ImVec2(mid, ay), ImVec2(mid, by), ImVec2(bx, by),
                                               color(rgb, 1.0), static_cast<float>(num(thickness)));
  }

  inline void rect(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const alpha, obj const rounding)
  {
    ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                              ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                              color(rgb, num(alpha)), static_cast<float>(num(rounding)));
  }

  inline void frame(obj const x1, obj const y1, obj const x2, obj const y2, obj const rgb, obj const thickness)
  {
    ImGui::GetWindowDrawList()->AddRect(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                        ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                        color(rgb, 1.0), 0.0f, 0, static_cast<float>(num(thickness)));
  }

  inline void circle(obj const x, obj const y, obj const radius, obj const rgb, obj const alpha)
  {
    ImGui::GetWindowDrawList()->AddCircleFilled(ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))),
                                                static_cast<float>(num(radius)), color(rgb, num(alpha)), 24);
  }

  inline void triangle(obj const x1, obj const y1, obj const x2, obj const y2, obj const x3, obj const y3,
                       obj const rgb, obj const alpha)
  {
    ImGui::GetWindowDrawList()->AddTriangleFilled(ImVec2(static_cast<float>(num(x1)), static_cast<float>(num(y1))),
                                                  ImVec2(static_cast<float>(num(x2)), static_cast<float>(num(y2))),
                                                  ImVec2(static_cast<float>(num(x3)), static_cast<float>(num(y3))),
                                                  color(rgb, num(alpha)));
  }

  inline void ring(obj const x, obj const y, obj const radius, obj const rgb, obj const thickness)
  {
    ImGui::GetWindowDrawList()->AddCircle(ImVec2(static_cast<float>(num(x)), static_cast<float>(num(y))),
                                          static_cast<float>(num(radius)), color(rgb, 1.0), 24, static_cast<float>(num(thickness)));
  }

  /* Arrays of numbers kept here, by a number: a card's thousands of values are copied once
   * (when the card is made) and drawn from C++ every frame. */
  struct array
  {
    std::vector<float> values;
    float lo{}, hi{};
    double sum{};
    long argmax{};
  };

  /* Made on any thread, drawn on the main one: held by shared pointers, behind a lock. */
  inline std::mutex &arrays_lock()
  {
    static std::mutex lock;
    return lock;
  }

  inline std::vector<std::shared_ptr<array const>> &arrays()
  {
    static std::vector<std::shared_ptr<array const>> all;
    return all;
  }

  /* Any sequence of numbers; its number. */
  inline obj array_new(obj const numbers)
  {
    namespace rt = jank::runtime;
    auto made(std::make_shared<array>());
    auto &a(*made);
    for(auto s(rt::seq(numbers)); s != rt::jank_nil; s = rt::next(s))
    {
      a.values.push_back(static_cast<float>(num(rt::first(s))));
    }
    for(size_t i{}; i < a.values.size(); ++i)
    {
      auto const v(a.values[i]);
      if(i == 0 || v < a.lo)
      {
        a.lo = v;
      }
      if(i == 0 || v > a.hi)
      {
        a.hi = v;
        a.argmax = static_cast<long>(i);
      }
      a.sum += v;
    }
    std::lock_guard<std::mutex> const held(arrays_lock());
    arrays().push_back(std::move(made));
    return rt::make_box(static_cast<jank::i64>(arrays().size() - 1));
  }

  inline std::shared_ptr<array const> array_of(obj const id)
  {
    static std::shared_ptr<array const> const none(std::make_shared<array>());
    auto const i(static_cast<size_t>(num(id)));
    std::lock_guard<std::mutex> const held(arrays_lock());
    return i < arrays().size() ? arrays()[i] : none;
  }

  inline double array_size(obj const id) { return static_cast<double>(array_of(id)->values.size()); }
  inline double array_min(obj const id) { return array_of(id)->lo; }
  inline double array_max(obj const id) { return array_of(id)->hi; }
  inline double array_sum(obj const id) { return array_of(id)->sum; }
  inline double array_argmax(obj const id) { return static_cast<double>(array_of(id)->argmax); }

  inline double array_at(obj const id, obj const index)
  {
    auto const a(array_of(id));
    auto const i(static_cast<size_t>(num(index)));
    return i < a->values.size() ? a->values[i] : 0.0;
  }

  /* An array's values let go (its card is gone); its number stays taken. */
  inline void array_free(obj const id)
  {
    auto const i(static_cast<size_t>(num(id)));
    std::lock_guard<std::mutex> const held(arrays_lock());
    if(i < arrays().size())
    {
      arrays()[i] = std::make_shared<array>();
    }
  }

  /* Every array forgotten (the cards that drew them are gone). */
  inline void arrays_clear()
  {
    std::lock_guard<std::mutex> const held(arrays_lock());
    arrays().clear();
  }

  /* A value's colour: from the paper to `rgb` by its magnitude over the largest. */
  inline ImU32 shade(unsigned const rgb, float const share)
  {
    auto const t(share < 0.0f ? 0.0f : (share > 1.0f ? 1.0f : share));
    return IM_COL32((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff, static_cast<int>(t * 255.0f));
  }

  /* An array as a matrix [rows, cols] of cells in the rectangle: positive values in
   * `positive`, negative ones in `negative`, each as strong as its magnitude over the
   * largest. Columns narrower than a point are drawn a point each, the strongest value of
   * those it covers. */
  inline void heat(obj const id, obj const x, obj const y, obj const width, obj const height, obj const rows,
                   obj const cols, obj const positive, obj const negative)
  {
    auto const kept(array_of(id));
    auto const &a(*kept);
    auto const nr(static_cast<long>(num(rows))), nc(static_cast<long>(num(cols)));
    if(nr <= 0 || nc <= 0 || static_cast<size_t>(nr * nc) > a.values.size())
    {
      return;
    }
    auto const x0(static_cast<float>(num(x))), y0(static_cast<float>(num(y)));
    auto const w(static_cast<float>(num(width))), h(static_cast<float>(num(height)));
    auto const largest(std::max(std::fabs(a.lo), std::fabs(a.hi)));
    if(largest <= 0.0f)
    {
      return;
    }
    auto const pos(static_cast<unsigned>(num(positive))), neg(static_cast<unsigned>(num(negative)));
    auto const ch(h / static_cast<float>(nr));
    auto const drawn(std::min<long>(nc, std::max<long>(1, static_cast<long>(w))));
    auto const cw(w / static_cast<float>(drawn));
    auto *const list(ImGui::GetWindowDrawList());
    for(long r{}; r < nr; ++r)
    {
      for(long d{}; d < drawn; ++d)
      {
        auto const c0(d * nc / drawn), c1(std::max(c0 + 1, (d + 1) * nc / drawn));
        float v{};
        for(long c{ c0 }; c < c1; ++c)
        {
          auto const candidate(a.values[static_cast<size_t>(r * nc + c)]);
          if(std::fabs(candidate) > std::fabs(v))
          {
            v = candidate;
          }
        }
        if(v == 0.0f)
        {
          continue;
        }
        auto const gap(cw > 3.0f && ch > 3.0f ? 1.0f : 0.0f);
        list->AddRectFilled(ImVec2(x0 + cw * static_cast<float>(d), y0 + ch * static_cast<float>(r)),
                            ImVec2(x0 + cw * static_cast<float>(d + 1) - gap, y0 + ch * static_cast<float>(r + 1) - gap),
                            shade(v < 0.0f ? neg : pos, std::sqrt(std::fabs(v) / largest)));
      }
    }
  }

  /* An array as a series in the rectangle: a point a column, from the lowest to the highest
   * of the values it covers, over a line at zero. */
  inline void series(obj const id, obj const x, obj const y, obj const width, obj const height, obj const rgb)
  {
    auto const kept(array_of(id));
    auto const &a(*kept);
    auto const n(static_cast<long>(a.values.size()));
    if(n == 0)
    {
      return;
    }
    auto const x0(static_cast<float>(num(x))), y0(static_cast<float>(num(y)));
    auto const w(static_cast<float>(num(width))), h(static_cast<float>(num(height)));
    auto const lo(std::min(a.lo, 0.0f)), hi(std::max(a.hi, 0.0f));
    auto const span(hi - lo > 0.0f ? hi - lo : 1.0f);
    auto const at([&](float const v) { return y0 + h * (hi - v) / span; });
    auto const ink(color(rgb, 0.85));
    auto *const list(ImGui::GetWindowDrawList());
    auto const drawn(std::min<long>(n, std::max<long>(1, static_cast<long>(w))));
    auto const cw(w / static_cast<float>(drawn));
    for(long d{}; d < drawn; ++d)
    {
      auto const i0(d * n / drawn), i1(std::max(i0 + 1, (d + 1) * n / drawn));
      float low{ a.values[static_cast<size_t>(i0)] }, high{ low };
      for(long i{ i0 }; i < i1; ++i)
      {
        low = std::min(low, a.values[static_cast<size_t>(i)]);
        high = std::max(high, a.values[static_cast<size_t>(i)]);
      }
      /* A bar from zero when a column is one value, else the range it covers. */
      if(i1 - i0 == 1)
      {
        low = std::min(low, 0.0f);
        high = std::max(high, 0.0f);
      }
      list->AddRectFilled(ImVec2(x0 + cw * static_cast<float>(d), at(high)),
                          ImVec2(x0 + std::max(cw * static_cast<float>(d + 1) - (cw > 3.0f ? 1.0f : 0.0f), cw * static_cast<float>(d) + 1.0f),
                                 std::max(at(low), at(high) + 1.0f)),
                          ink);
    }
    list->AddLine(ImVec2(x0, at(0.0f)), ImVec2(x0 + w, at(0.0f)), IM_COL32(0x7a, 0x74, 0x66, 0xff), 1.0f);
  }
}
