// The inkling command: convert a checkpoint, inspect a model file, tokenize,
// and generate text.
#include "internal.hpp"

#include <cmath>
#include <map>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>

namespace
{
  void usage()
  {
    std::fprintf(stderr,
                 "usage:\n"
                 "  inkling convert SOURCE OUT.ink     checkpoint directory or manifest -> model file\n"
                 "  inkling info MODEL.ink             configuration, plan, tensors\n"
                 "  inkling tokenize MODEL.ink TEXT    token ids and pieces (special tokens allowed)\n"
                 "  inkling run MODEL.ink [options]    generate\n"
                 "  inkling score MODEL.ink PROMPT IDS [--cpu]\n"
                 "                                     log-probability of each of the ids (comma separated)\n"
                 "                                     after the prompt: id, logprob, our argmax\n"
                 "  inkling bench MODEL.ink [W...]     milliseconds of a forward over W rows (1 2 4 8 16)\n"
                 "  inkling gpucheck MODEL.ink PROMPT [--all]\n"
                 "                                     checks every GPU stage of every visit against the CPU\n"
                 "                                     on the CPU's inputs; --all prints every row\n"
                 "  inkling tapcheck MODEL.ink PROMPT  the hidden states kept for a draft model, against\n"
                 "                                     the captures, and through a check rolled back\n"
                 "  inkling draftcheck MODEL.ink PROMPT\n"
                 "                                     the draft model on the GPU against its CPU version,\n"
                 "                                     from the same hidden states\n"
                 "  inkling rowcheck MODEL.ink PROMPT [ROWS]\n"
                 "                                     evaluates ROWS (8) tokens after the prompt in one\n"
                 "                                     forward, keeping each row's logits, and compares\n"
                 "                                     them bit by bit with one token at a time, then\n"
                 "                                     rolls back to 3 of them and goes on, compared again\n"
                 "    -p TEXT      prompt, used as is (special tokens allowed)\n"
                 "    -n N         tokens to generate (default 64)\n"
                 "    -t TEMP      temperature (default 0: greedy)\n"
                 "    --threads N  CPU threads\n"
                 "    --cpu        run on the CPU (the reference path)\n"
                 "    --ctx N      context (default 8192)\n"
                 "    --top N      print the top N logits after the prompt\n"
                 "    --draft N    draft from the context (matches of at least N tokens) and check\n"
                 "                 the drafts in one forward: the same tokens, sooner\n"
                 "    --dspark K   draft up to K tokens with the draft model (when the context has\n"
                 "                 no match), checked the same way\n"
                 "    --dspark-fixed K  the same, always K tokens (to measure how many are kept)\n");
  }

  double now()
  {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
  }
}

int main(int argc, char **argv)
{
  try
  {
    if(argc < 2)
    {
      usage();
      return 2;
    }
    std::string const cmd{ argv[1] };
    if(cmd == "convert" && argc == 4)
    {
      inkling::convert(argv[2], argv[3]);
      return 0;
    }
    if(argc < 3)
    {
      usage();
      return 2;
    }
    double const t0{ now() };
    std::unique_ptr<inkling::model, void (*)(inkling::model *)> m{ inkling::open(argv[2]), inkling::close };
    double const t1{ now() };
    auto const &c{ m->cfg };
    if(cmd == "info")
    {
      std::printf("loaded in %.2f s\nlayers %d, hidden %d, vocab %d (%d used), heads %d/%d (local %d/%d), experts %d top %d "
                  "width %d\nloop layers [%d, %d) x %d, residual blocks of %d, window %d\nplan: %zu visits\n",
                  t1 - t0,
                  c.layers,
                  c.hidden,
                  c.vocab,
                  c.unpadded_vocab,
                  c.heads,
                  c.kv_heads,
                  c.local_heads,
                  c.local_kv_heads,
                  c.experts,
                  c.top_k,
                  c.expert_width,
                  c.loop_start,
                  c.loop_end,
                  c.loop_passes,
                  c.residual_block,
                  c.window,
                  m->plan.size());
      for(size_t i{}; i < m->plan.size(); ++i)
      {
        auto const &v{ m->plan[i] };
        std::printf("  v%zu: layer %d pass %d %s\n", i, v.layer, v.pass, v.local ? "local" : "global");
      }
      std::printf("tensors: %zu, threads %d\n", m->tensors.size(), m->threads);
      return 0;
    }
    if(cmd == "tokenize" && argc == 4)
    {
      auto const ids{ inkling::tokenize(*m, argv[3], true) };
      for(auto const id : ids)
      {
        auto const piece{ inkling::detokenize(*m, &id, 1) };
        std::printf("%d\t%s\n", id, piece.c_str());
      }
      return 0;
    }
    if(cmd == "rowcheck" && (argc == 4 || argc == 5))
    {
      // A draft's check must give each row the bits a decode step gives it: the
      // tokens after the prompt are its own greedy continuation.
      int const rows{ argc == 5 ? std::atoi(argv[4]) : 8 };
      auto const prompt{ inkling::tokenize(*m, argv[3], true) };
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> serial{ inkling::new_session(*m, 8192),
                                                                               inkling::free_session };
      inkling::eval(*serial, prompt);
      std::vector<int32_t> next;
      std::vector<std::vector<float>> logits;
      uint64_t rng{ 1 };
      for(int i{}; i < rows; ++i)
      {
        auto const id{ inkling::sample(serial->logits.data(), static_cast<int32_t>(serial->logits.size()), 0.0f,
                                       1.0f, 0, rng) };
        next.push_back(id);
        inkling::eval(*serial, &next.back(), 1);
        logits.push_back(serial->logits);
      }
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> batch{ inkling::new_session(*m, 8192),
                                                                              inkling::free_session };
      inkling::eval(*batch, prompt);
      batch->all_logits = true;
      inkling::eval(*batch, next);
      size_t const v{ logits[0].size() };
      bool all_same{ true };
      for(int r{}; r < rows; ++r)
      {
        size_t differ{};
        double worst{};
        for(size_t i{}; i < v; ++i)
        {
          float const a{ logits[static_cast<size_t>(r)][i] };
          float const b{ batch->row_logits[static_cast<size_t>(r) * v + i] };
          if(std::memcmp(&a, &b, sizeof a) != 0)
          {
            ++differ;
            worst = std::max(worst, static_cast<double>(std::fabs(a - b)));
          }
        }
        all_same = all_same && differ == 0;
        std::printf("row %d (position %zu): %zu of %zu logits differ, worst %.3g\n", r, prompt.size() + r, differ, v,
                    worst);
      }
      // Rolled back to 5 of the rows, then to 3 (twice within the check), then on
      // one token at a time: the same bits again.
      int const keep{ std::min(3, rows - 1) };
      inkling::truncate(*batch, static_cast<int32_t>(prompt.size()) + std::min(5, rows - 1));
      inkling::truncate(*batch, static_cast<int32_t>(prompt.size()) + keep);
      batch->all_logits = false;
      bool rolled{ std::memcmp(batch->logits.data(), logits[static_cast<size_t>(keep - 1)].data(), v * sizeof(float)) == 0 };
      for(int r{ keep }; r < rows; ++r)
      {
        inkling::eval(*batch, &next[static_cast<size_t>(r)], 1);
        rolled = rolled && std::memcmp(batch->logits.data(), logits[static_cast<size_t>(r)].data(), v * sizeof(float)) == 0;
      }
      std::printf(rolled ? "OK: rolled back to %d rows and on, the same bits as one token at a time\n"
                         : "DIFFERENT: rolled back to %d rows and on, not the same as one token at a time\n",
                  keep);
      all_same = all_same && rolled;
      std::printf(all_same ? "OK: every row is the same bits as one token at a time\n"
                           : "DIFFERENT: rows of one forward aren't one token at a time\n");
      return all_same ? 0 : 1;
    }

    if(cmd == "bench" && argc >= 3)
    {
      // Milliseconds of one forward over W rows at position 1000 (each the median
      // of 7, from the same state), for W in the arguments (1 2 4 8 16 by default).
      std::vector<int32_t> widths;
      for(int i{ 3 }; i < argc; ++i)
      {
        widths.push_back(std::stoi(argv[i]));
      }
      if(widths.empty())
      {
        widths = { 1, 2, 4, 8, 16 };
      }
      auto const piece{ inkling::tokenize(*m, "The quick brown fox jumps over the lazy dog while the cat watches from the window. ", false) };
      std::vector<int32_t> filler;
      while(filler.size() < 1100)
      {
        filler.insert(filler.end(), piece.begin(), piece.end());
      }
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, 8192), inkling::free_session };
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> snap{ inkling::new_session(*m, 8192),
                                                                             inkling::free_session };
      inkling::eval(*s, filler.data(), 1000);
      inkling::copy(*snap, *s);
      for(auto const w : widths)
      {
        inkling::eval(*s, filler.data() + 1000, w);
        std::vector<double> times;
        for(int i{}; i < 7; ++i)
        {
          inkling::copy(*s, *snap);
          auto const t0{ std::chrono::steady_clock::now() };
          inkling::eval(*s, filler.data() + 1000, w);
          times.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
        }
        std::sort(times.begin(), times.end());
        std::printf("%2d rows: %6.1f ms\n", w, times[3]);
      }
      return 0;
    }

    if(cmd == "draftcheck" && argc == 4)
    {
      // The draft model on the GPU against its CPU version (the reference), from
      // the same hidden states: after each token of a greedy continuation, both
      // draft 7 tokens after the next one; how often they agree.
      if(!m->gpu)
      {
        std::fprintf(stderr, "no Metal backend for this model\n");
        return 1;
      }
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, 4096), inkling::free_session };
      std::unique_ptr<inkling::drafter, void (*)(inkling::drafter *)> cpu{ inkling::new_drafter(*s, true), inkling::free_drafter };
      std::unique_ptr<inkling::drafter, void (*)(inkling::drafter *)> gpu{ inkling::new_drafter(*s), inkling::free_drafter };
      inkling::eval(*s, inkling::tokenize(*m, argv[3], true));
      int first{}, all{}, steps{};
      std::vector<int> by_place(7);
      for(int i{}; i < 48; ++i)
      {
        uint64_t rng{ 1 };
        int32_t const next{ inkling::sample(s->logits.data(), static_cast<int32_t>(s->logits.size()), 0, 1, 0, rng) };
        auto const g{ inkling::draft(*gpu, *s, next, 7) };
        auto const c{ inkling::draft(*cpu, *s, next, 7) };
        ++steps;
        first += !g.empty() && !c.empty() && g[0] == c[0];
        all += g == c;
        for(size_t j{}; j < 7 && j < g.size() && j < c.size(); ++j)
        {
          if(g[j] != c[j])
          {
            break;
          }
          ++by_place[j];
        }
        inkling::eval(*s, &next, 1);
      }
      std::printf("%d drafts: the first proposal the same in %d, all 7 in %d; the same up to place:", steps, first, all);
      for(auto const n : by_place) std::printf(" %d", n);
      std::printf("\n");
      // The two differ in rounding (BF16 logits, the fold of the output head), so
      // a near tie can go either way; a mistake shows as many differences.
      bool const ok{ first * 20 >= steps * 19 };
      std::printf(ok ? "OK: the GPU drafts as the CPU version does\n" : "DIFFERENT: the GPU drafts otherwise\n");
      return ok ? 0 : 1;
    }

    if(cmd == "tapcheck" && argc == 4)
    {
      // The hidden states kept for a draft model: each path's against its own
      // captures (the same bits), the GPU's against the CPU's (for information),
      // and, on the GPU, a check rolled back and continued against one token at
      // a time (the same bits).
      if(!m->gpu)
      {
        std::fprintf(stderr, "no Metal backend for this model\n");
        return 1;
      }
      std::vector<int32_t> const visits{ 5, 23, 41 };
      auto const prompt{ inkling::tokenize(*m, argv[3], true) };
      auto const fresh{ [&](bool gpu) {
        m->use_gpu = gpu;
        std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, 4096),
                                                                            inkling::free_session };
        inkling::keep_taps(*s, visits);
        return s;
      } };
      size_t const h{ static_cast<size_t>(m->cfg.hidden) };
      size_t const row{ (visits.size() + 1) * h };
      auto const bf{ [](uint16_t b) {
        uint32_t const u{ static_cast<uint32_t>(b) << 16 };
        float f;
        std::memcpy(&f, &u, 4);
        return f;
      } };
      // Each path's taps against its own captures: the partial sum after visit
      // v - 1 is the one entering visit v (5, 23 and 41 restart no loop), and
      // the last token's final norm output is captured.
      auto const own{ [&](bool gpu) {
        auto s{ fresh(gpu) };
        s->capturing = true;
        inkling::eval(*s, prompt);
        auto const &cap{ s->captured };
        bool same{ cap.tokens == static_cast<int32_t>(prompt.size()) };
        for(size_t tp{}; same && tp < visits.size(); ++tp)
        {
          auto const &partial{ cap.visits[static_cast<size_t>(visits[tp] - 1)].partial };
          for(size_t p{}; p < prompt.size(); ++p)
          {
            for(size_t i{}; i < h; ++i)
            {
              uint32_t bits;
              std::memcpy(&bits, &partial[p * h + i], 4);
              same = same && s->tap_ring[p * row + tp * h + i] == static_cast<uint16_t>(bits >> 16);
            }
          }
        }
        for(size_t i{}; same && i < h; ++i)
        {
          uint32_t bits;
          std::memcpy(&bits, &cap.hidden[i], 4);
          same = s->tap_ring[(prompt.size() - 1) * row + visits.size() * h + i] == static_cast<uint16_t>(bits >> 16);
        }
        std::printf("%s: the taps are %s the captured partial sums and final norm output\n", gpu ? "GPU" : "CPU",
                    same ? "the same bits as" : "NOT");
        return std::pair{ std::move(s), same };
      } };
      auto [cpu, cpu_same] { own(false) };
      auto [gpu, gpu_same] { own(true) };
      // GPU against CPU: the forwards differ in rounding, and the differences grow
      // through the visits, so this is for information.
      for(size_t tp{}; tp <= visits.size(); ++tp)
      {
        double worst{};
        for(size_t p{}; p < prompt.size(); ++p)
        {
          for(size_t i{}; i < h; ++i)
          {
            float const a{ bf(cpu->tap_ring[p * row + tp * h + i]) };
            float const b{ bf(gpu->tap_ring[p * row + tp * h + i]) };
            worst = std::max(worst, static_cast<double>(std::fabs(a - b)) / std::max(1.0, static_cast<double>(std::fabs(a))));
          }
        }
        std::printf("  GPU against CPU, tap %zu (%s): worst relative difference %.3g\n", tp,
                    tp < visits.size() ? ("visit " + std::to_string(visits[tp])).c_str() : "final norm", worst);
      }
      gpu->capturing = false;
      // The GPU's continuation: one token at a time, and a check of 8 rolled back to 3.
      std::vector<int32_t> next;
      {
        uint64_t rng{ 1 };
        for(int i{}; i < 8; ++i)
        {
          next.push_back(inkling::sample(gpu->logits.data(), static_cast<int32_t>(gpu->logits.size()), 0, 1, 0, rng));
          inkling::eval(*gpu, &next.back(), 1);
        }
      }
      auto checked{ fresh(true) };
      inkling::eval(*checked, prompt);
      checked->all_logits = true;
      inkling::eval(*checked, next);
      checked->all_logits = false;
      inkling::truncate(*checked, static_cast<int32_t>(prompt.size()) + 3);
      for(size_t i{ 3 }; i < next.size(); ++i)
      {
        inkling::eval(*checked, &next[i], 1);
      }
      bool same{ true };
      for(size_t p{}; p < prompt.size() + next.size(); ++p)
      {
        same = same && std::memcmp(gpu->tap_ring + p * row, checked->tap_ring + p * row, row * 2) == 0;
      }
      std::printf(same ? "OK: a check rolled back and continued keeps the same taps as one token at a time\n"
                       : "DIFFERENT: a check rolled back and continued keeps other taps\n");
      return same && cpu_same && gpu_same ? 0 : 1;
    }

    if(cmd == "gpucheck" && (argc == 4 || argc == 5))
    {
      if(!m->gpu)
      {
        std::fprintf(stderr, "no Metal backend for this model\n");
        return 1;
      }
      bool const all{ argc == 5 && std::string{ argv[4] } == "--all" };
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, 8192),
                                                                          inkling::free_session };
      auto const report{ inkling::check_gpu(*s, inkling::tokenize(*m, argv[3], true)) };
      std::map<std::string, inkling::check_row> by_field;
      std::vector<std::string> order;
      for(auto const &r : report.rows)
      {
        if(all || r.beyond > 0)
        {
          std::printf("v%-2d %-18s %9lld values, %7lld differ, %6lld beyond tolerance, worst %.3g\n", r.visit,
                      r.field.c_str(), static_cast<long long>(r.count), static_cast<long long>(r.different),
                      static_cast<long long>(r.beyond), r.worst);
        }
        if(!by_field.count(r.field))
        {
          order.push_back(r.field);
          by_field[r.field].field = r.field;
        }
        auto &t{ by_field[r.field] };
        t.count += r.count;
        t.different += r.different;
        t.beyond += r.beyond;
        t.worst = std::max(t.worst, r.worst);
      }
      std::printf("%-18s %12s %10s %8s %8s\n", "field", "values", "differ", "beyond", "worst");
      for(auto const &name : order)
      {
        auto const &t{ by_field[name] };
        std::printf("%-18s %12lld %10lld %8lld %8.3g\n", name.c_str(), static_cast<long long>(t.count),
                    static_cast<long long>(t.different), static_cast<long long>(t.beyond), t.worst);
      }
      std::printf("%s: %lld values compared, %lld beyond tolerance\n", report.ok() ? "OK" : "FAILED",
                  static_cast<long long>(report.compared), static_cast<long long>(report.beyond));
      return report.ok() ? 0 : 1;
    }
    if(cmd == "score" && (argc == 5 || argc == 6))
    {
      if(argc == 6 && std::string{ argv[5] } == "--cpu")
      {
        m->use_gpu = false;
      }
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, 8192),
                                                                          inkling::free_session };
      inkling::eval(*s, inkling::tokenize(*m, argv[3], true));
      std::string const list{ argv[4] };
      size_t at{};
      while(at < list.size())
      {
        auto const comma{ list.find(',', at) };
        auto const id{ static_cast<int32_t>(std::stol(list.substr(at, comma - at))) };
        at = comma == std::string::npos ? list.size() : comma + 1;
        auto const &lg{ s->logits };
        float const best{ *std::max_element(lg.begin(), lg.end()) };
        double sum{};
        for(auto const l : lg)
        {
          sum += std::exp(static_cast<double>(l - best));
        }
        double const lse{ best + std::log(sum) };
        auto const arg{ static_cast<int32_t>(std::max_element(lg.begin(), lg.end()) - lg.begin()) };
        std::printf("%d\t%.5f\t%d\n", id, lg[static_cast<size_t>(id)] - lse, arg);
        std::fflush(stdout);
        inkling::eval(*s, &id, 1);
      }
      return 0;
    }
    if(cmd == "run")
    {
      std::string prompt{ "Hello" };
      int32_t n{ 64 };
      float temp{ 0 };
      int32_t ctx{ 8192 };
      int32_t top{ 0 };
      int32_t draft{ 0 };
      int32_t dspark{ -1 };
      bool fixed{};
      for(int i{ 3 }; i < argc; ++i)
      {
        std::string const a{ argv[i] };
        auto const next{ [&] {
          if(i + 1 >= argc)
          {
            usage();
            std::exit(2);
          }
          return std::string{ argv[++i] };
        } };
        if(a == "-p")
        {
          prompt = next();
        }
        else if(a == "-n")
        {
          n = std::stoi(next());
        }
        else if(a == "-t")
        {
          temp = std::stof(next());
        }
        else if(a == "--threads")
        {
          inkling::set_threads(*m, std::stoi(next()));
        }
        else if(a == "--cpu")
        {
          m->use_gpu = false;
        }
        else if(a == "--ctx")
        {
          ctx = std::stoi(next());
        }
        else if(a == "--top")
        {
          top = std::stoi(next());
        }
        else if(a == "--draft")
        {
          draft = std::stoi(next());
        }
        else if(a == "--dspark")
        {
          dspark = std::stoi(next());
        }
        else if(a == "--dspark-fixed")
        {
          dspark = std::stoi(next());
          fixed = true;
        }
        else
        {
          usage();
          return 2;
        }
      }
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, ctx),
                                                                          inkling::free_session };
      auto const ids{ inkling::tokenize(*m, prompt, true) };
      // The session's own draft model (its forwards keep the drafter's context).
      if(dspark >= 0)
      {
        inkling::use_draft_model(*s, dspark);
        inkling::set_draft_depth(*s->draft_model, dspark, !fixed);
      }
      bool const drafting{ draft > 0 || dspark >= 0 };
      double const p0{ now() };
      inkling::eval(*s, ids);
      double const p1{ now() };
      std::fprintf(stderr, "prompt: %zu tokens in %.2f s (%.1f tok/s)\n", ids.size(), p1 - p0, ids.size() / (p1 - p0));
      if(top > 0)
      {
        std::vector<int32_t> idx(s->logits.size());
        for(size_t i{}; i < idx.size(); ++i)
        {
          idx[i] = static_cast<int32_t>(i);
        }
        std::partial_sort(idx.begin(), idx.begin() + top, idx.end(), [&](int32_t a, int32_t b) {
          return s->logits[static_cast<size_t>(a)] > s->logits[static_cast<size_t>(b)];
        });
        for(int32_t i{}; i < top; ++i)
        {
          auto const id{ idx[static_cast<size_t>(i)] };
          std::printf("%d\t%.4f\t%s\n", id, s->logits[static_cast<size_t>(id)], inkling::detokenize(*m, &id, 1).c_str());
        }
      }
      // Token i sampled with the generator seeded (seed + i) | 1, with or without drafts,
      // so that the two give the same tokens.
      uint64_t const seed{ 0x9e3779b97f4a7c15ull };
      double const g0{ now() };
      int32_t produced{};
      int32_t checks{};
      // Forwards by the number of tokens they gave.
      std::vector<int32_t> gave(17);
      bool ended{};
      while(produced < n && !ended)
      {
        std::vector<int32_t> ids;
        if(drafting)
        {
          // Without --draft, no copies from the context: a match can't be that long.
          ids = inkling::speculate(*s, temp, 0.95f, 0, seed + static_cast<uint64_t>(produced), n - produced,
                                   draft > 0 ? draft : 1 << 30, 15);
          ++checks;
          ++gave[std::min<size_t>(ids.size(), 16)];
        }
        else
        {
          uint64_t rng{ (seed + static_cast<uint64_t>(produced)) | 1u };
          ids = { inkling::sample(s->logits.data(), static_cast<int32_t>(s->logits.size()), temp, 0.95f, 0, rng) };
          inkling::eval(*s, ids);
        }
        for(auto const id : ids)
        {
          std::fputs(inkling::detokenize(*m, &id, 1).c_str(), stdout);
          ++produced;
          if(id == c.eos_token)
          {
            ended = true;
            break;
          }
        }
        std::fflush(stdout);
      }
      double const g1{ now() };
      std::fprintf(stderr, "\ngenerated %d tokens in %.2f s (%.2f tok/s)", produced, g1 - g0, produced / (g1 - g0));
      if(drafting)
      {
        std::fprintf(stderr, ", %d forwards (%.2f tokens each; by tokens given:", checks, static_cast<double>(produced) / checks);
        for(size_t i{ 1 }; i < gave.size(); ++i)
        {
          if(gave[i] > 0)
          {
            std::fprintf(stderr, " %zu: %d", i, gave[i]);
          }
        }
        std::fprintf(stderr, ")");
      }
      std::fprintf(stderr, "\n");
      return 0;
    }
    usage();
    return 2;
  }
  catch(std::exception const &e)
  {
    std::fprintf(stderr, "%s\n", e.what());
    return 1;
  }
}
