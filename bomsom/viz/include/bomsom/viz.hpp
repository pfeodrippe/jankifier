#pragma once

// The C++ of bomsom's cards: what's measured every frame from the monitor synth's buffer (the
// newest frames of the output and their spectrum), drawn with the cards' series primitives
// (cards::polyline_of, cards::area_of), and a slider for a synth's control. Reading the
// server's memory from the window's thread while the audio thread writes it: a number read
// may be a block old, which a picture doesn't mind. The cards themselves are jank
// (bomsom.cards).

#include <bomsom/server.hpp>
#include <cards/cards.hpp>

#include <algorithm>
#include <cmath>
#include <complex>

namespace bomsom::viz
{
  inline double sample_rate(World const *w) { return w->mSampleRate; }
  inline int64_t blocks(World const *w) { return w->mBufCounter; }
  inline int64_t block_size(World const *w) { return w->mBufLength; }

  inline double control_bus(World const *w, int64_t i)
  {
    return i >= 0 && i < static_cast<int64_t>(w->mNumControlBusChannels) ? w->mControlBus[i] : 0.0;
  }

  inline double db(double amplitude) { return 20.0 * std::log10(std::max(amplitude, 1.0e-6)); }

  inline ImU32 rgba(int64_t rgb, double alpha)
  {
    return IM_COL32((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff, static_cast<int>(alpha * 255.0));
  }

  // The newest frames of the output, both channels, copied each frame.
  inline constexpr int frames{ 2048 };
  inline float left[frames], right[frames];

  // The scope: `shown` frames from an upward zero crossing of the left channel (so a steady
  // sound stands still), as `scope_points` points.
  inline constexpr int shown{ 1024 };
  inline constexpr int scope_points{ 512 };
  inline float left_drawn[scope_points], right_drawn[scope_points];

  // The spectrum of both channels' mean: `spectrum_points` points from 30 Hz to 18 kHz on a log
  // axis, in dB, falling back slowly as analysers do.
  inline constexpr int spectrum_points{ 300 };
  inline constexpr double lowest_hz{ 30.0 }, highest_hz{ 18000.0 };
  inline float spectrum[spectrum_points];
  inline bool measured{}, spectrum_started{};

  inline void fft(std::complex<float> *a, int n)
  {
    for(int i{ 1 }, j{}; i < n; ++i)
    {
      int bit{ n >> 1 };
      for(; j & bit; bit >>= 1) { j ^= bit; }
      j ^= bit;
      if(i < j) { std::swap(a[i], a[j]); }
    }
    for(int len{ 2 }; len <= n; len <<= 1)
    {
      float const angle{ -2.0f * static_cast<float>(M_PI) / static_cast<float>(len) };
      std::complex<float> const step{ std::cos(angle), std::sin(angle) };
      for(int i{}; i < n; i += len)
      {
        std::complex<float> turn{ 1.0f, 0.0f };
        for(int k{}; k < len / 2; ++k)
        {
          auto const u{ a[i + k] }, v{ a[i + k + len / 2] * turn };
          a[i + k] = u + v;
          a[i + k + len / 2] = u - v;
          turn *= step;
        }
      }
    }
  }

  // Copies the newest frames from the buffer that the monitor synth writes in a loop (BufWr
  // with a Phasor, whose position is on `phase_bus`), then makes the scope's points and the
  // spectrum. False while there's no such buffer.
  inline bool measure(World const *w, int64_t bufnum, int64_t phase_bus)
  {
    measured = false;
    if(!w || bufnum < 0 || bufnum >= static_cast<int64_t>(w->mNumSndBufs)
       || phase_bus < 0 || phase_bus >= static_cast<int64_t>(w->mNumControlBusChannels))
    {
      return false;
    }
    SndBuf const &b{ w->mSndBufs[bufnum] };
    if(!b.data || b.channels < 2 || b.frames < frames)
    {
      return false;
    }
    auto const end{ static_cast<int64_t>(w->mControlBus[phase_bus]) };
    for(int i{}; i < frames; ++i)
    {
      auto f{ (end - frames + i) % b.frames };
      if(f < 0) { f += b.frames; }
      left[i] = b.data[f * b.channels];
      right[i] = b.data[f * b.channels + 1];
    }

    int start{ frames - shown };
    for(int i{ frames - shown }; i > frames - shown - 900 && i > 0; --i)
    {
      if(left[i - 1] < 0.0f && left[i] >= 0.0f)
      {
        start = i;
        break;
      }
    }
    for(int p{}; p < scope_points; ++p)
    {
      int const i{ start + p * shown / scope_points };
      left_drawn[p] = left[i];
      right_drawn[p] = right[i];
    }

    static std::complex<float> x[frames];
    for(int i{}; i < frames; ++i)
    {
      float const hann{ 0.5f - 0.5f * std::cos(2.0f * static_cast<float>(M_PI) * static_cast<float>(i)
                                               / static_cast<float>(frames - 1)) };
      x[i] = 0.5f * (left[i] + right[i]) * hann;
    }
    fft(x, frames);
    double const rate{ w->mSampleRate > 0.0 ? w->mSampleRate : 44100.0 };
    // A sine of amplitude A gives |X| = A N / 4 under a Hann window.
    auto const magnitude([&](int k) { return static_cast<double>(std::abs(x[k])) * 4.0 / frames; });
    for(int p{}; p < spectrum_points; ++p)
    {
      double const f0{ lowest_hz * std::pow(highest_hz / lowest_hz, static_cast<double>(p) / spectrum_points) };
      double const f1{ lowest_hz * std::pow(highest_hz / lowest_hz, static_cast<double>(p + 1) / spectrum_points) };
      double const b0{ f0 * frames / rate }, b1{ f1 * frames / rate };
      double m{};
      if(b1 - b0 < 1.0)
      {
        double const at{ (b0 + b1) / 2.0 };
        int const k{ static_cast<int>(at) };
        double const t{ at - k };
        if(k + 1 < frames / 2) { m = magnitude(k) + (magnitude(k + 1) - magnitude(k)) * t; }
      }
      else
      {
        for(int k{ static_cast<int>(std::ceil(b0)) }; k < static_cast<int>(b1) && k < frames / 2; ++k)
        {
          m = std::max(m, magnitude(k));
        }
      }
      auto const level{ static_cast<float>(db(m)) };
      spectrum[p] = spectrum_started ? std::max(level, spectrum[p] - 1.2f) : level;
    }
    spectrum_started = true;
    measured = true;
    return true;
  }

  // The scope in the rectangle, -scale..scale its height: the right channel, then the left
  // over it, each over a wider faint copy of itself.
  inline void draw_scope(double x, double y, double w, double h, double scale, int64_t left_rgb, int64_t right_rgb)
  {
    if(!measured) { return; }
    auto const fx{ static_cast<float>(x) }, fy{ static_cast<float>(y) };
    auto const fw{ static_cast<float>(w) }, fh{ static_cast<float>(h) }, s{ static_cast<float>(scale) };
    cards::polyline_of(right_drawn, scope_points, fx, fy, fw, fh, -s, s, rgba(right_rgb, 0.16), 6.0f);
    cards::polyline_of(right_drawn, scope_points, fx, fy, fw, fh, -s, s, rgba(right_rgb, 0.9), 1.5f);
    cards::polyline_of(left_drawn, scope_points, fx, fy, fw, fh, -s, s, rgba(left_rgb, 0.16), 6.0f);
    cards::polyline_of(left_drawn, scope_points, fx, fy, fw, fh, -s, s, rgba(left_rgb, 0.95), 1.5f);
  }

  // The spectrum in the rectangle, `floor_db`..0 dB its height: the area under it fading down,
  // and its line.
  inline void draw_spectrum(double x, double y, double w, double h, double floor_db, int64_t rgb)
  {
    if(!measured) { return; }
    auto const fx{ static_cast<float>(x) }, fy{ static_cast<float>(y) };
    auto const fw{ static_cast<float>(w) }, fh{ static_cast<float>(h) }, lo{ static_cast<float>(floor_db) };
    cards::area_of(spectrum, spectrum_points, fx, fy, fw, fh, lo, 0.0f, rgba(rgb, 0.5), rgba(rgb, 0.03));
    cards::polyline_of(spectrum, spectrum_points, fx, fy, fw, fh, lo, 0.0f, rgba(rgb, 0.95), 1.5f);
  }

  // Where a frequency is on the spectrum's axis, from 0 to 1.
  inline double spectrum_at(double hz)
  {
    return std::log(hz / lowest_hz) / std::log(highest_hz / lowest_hz);
  }

  inline ImVec4 rgba4(int64_t rgb, float alpha)
  {
    return ImVec4(static_cast<float>((rgb >> 16) & 0xff) / 255.0f, static_cast<float>((rgb >> 8) & 0xff) / 255.0f,
                  static_cast<float>(rgb & 0xff) / 255.0f, alpha);
  }

  // A slider for a synth's control at ImGui's cursor, styled as the dark panels (the handle
  // cyan, amber while held): 1 when it moved, 2 while it's held, 0 otherwise. `id` is ImGui's
  // (a "##..." label: the control's name is drawn by the card).
  inline int64_t slider(jank::runtime::object_ref const id, float *value, double lo, double hi, double width,
                        bool logarithmic)
  {
    ImGui::PushStyleColor(ImGuiCol_FrameBg, rgba4(0x121419, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, rgba4(0x1d2129, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_FrameBgActive, rgba4(0x1d2129, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_SliderGrab, rgba4(0x3fd3ea, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_SliderGrabActive, rgba4(0xffae4c, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_Text, rgba4(0xe4e8f0, 1.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 6.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_GrabRounding, 5.0f);
    ImGui::PushStyleVar(ImGuiStyleVar_GrabMinSize, 12.0f);
    ImGui::SetNextItemWidth(static_cast<float>(width));
    auto const name{ to_std(id) };
    bool const moved{ ImGui::SliderFloat(name.c_str(), value, static_cast<float>(lo), static_cast<float>(hi), "%.2f",
                                         logarithmic ? ImGuiSliderFlags_Logarithmic : ImGuiSliderFlags_None) };
    bool const held{ ImGui::IsItemActive() };
    ImGui::PopStyleVar(3);
    ImGui::PopStyleColor(6);
    return moved ? 1 : (held ? 2 : 0);
  }
}
