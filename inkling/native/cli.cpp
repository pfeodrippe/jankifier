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
                 "  inkling gpucheck MODEL.ink PROMPT [--all]\n"
                 "  inkling rowcheck MODEL.ink PROMPT [ROWS]\n"
                 "                                     evaluates ROWS (8) tokens after the prompt in one\n"
                 "                                     forward, keeping each row's logits, and compares\n"
                 "                                     them bit by bit with one token at a time, then\n"
                 "                                     rolls back to 3 of them and goes on, compared again\n"
                 "                                     checks every GPU stage of every visit against the CPU\n"
                 "                                     on the CPU's inputs; --all prints every row\n"
                 "    -p TEXT      prompt, used as is (special tokens allowed)\n"
                 "    -n N         tokens to generate (default 64)\n"
                 "    -t TEMP      temperature (default 0: greedy)\n"
                 "    --threads N  CPU threads\n"
                 "    --cpu        run on the CPU (the reference path)\n"
                 "    --ctx N      context (default 8192)\n"
                 "    --top N      print the top N logits after the prompt\n"
                 "    --draft N    draft from the context (matches of at least N tokens) and check\n"
                 "                 the drafts in one forward: the same tokens, sooner\n");
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
      // Rolled back to 3 of the rows, then on one token at a time: the same bits again.
      int const keep{ std::min(3, rows - 1) };
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
        else
        {
          usage();
          return 2;
        }
      }
      std::unique_ptr<inkling::session, void (*)(inkling::session *)> s{ inkling::new_session(*m, ctx),
                                                                          inkling::free_session };
      auto const ids{ inkling::tokenize(*m, prompt, true) };
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
      bool ended{};
      while(produced < n && !ended)
      {
        std::vector<int32_t> ids;
        if(draft > 0)
        {
          ids = inkling::speculate(*s, temp, 0.95f, 0, seed + static_cast<uint64_t>(produced), n - produced, draft, 15);
          ++checks;
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
      if(draft > 0)
      {
        std::fprintf(stderr, ", %d forwards (%.2f tokens each)", checks, static_cast<double>(produced) / checks);
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
