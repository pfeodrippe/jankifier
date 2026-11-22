// The tokenizer: byte-level BPE (tokenizer.json), with the split pattern of
// the checkpoint's pre-tokenizer written out by hand:
//
//   [^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?
//  |[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?
//  |\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+
//
// Each alternative is matched the way a backtracking regex engine does: the
// first alternative that matches at a position wins.
#include "internal.hpp"
#include "json.hpp"

#include <algorithm>

namespace inkling
{
  namespace
  {
    struct unicode_range
    {
      uint32_t first;
      uint32_t last;
      uint8_t flags;
    };

#include "unicode_table.inc"

    enum : uint8_t
    {
      LU = 1,
      LL = 2,
      LT = 4,
      LM = 8,
      LO = 16,
      MARK = 32,
      NUM = 64,
      WHITE = 128,
      LETTER = LU | LL | LT | LM | LO
    };

    uint8_t classes(uint32_t const cp)
    {
      auto const *begin{ std::begin(unicode_ranges) };
      auto const *end{ std::end(unicode_ranges) };
      auto const it{ std::upper_bound(begin, end, cp, [](uint32_t c, unicode_range const &r) { return c < r.first; }) };
      if(it == begin)
      {
        return 0;
      }
      auto const &r{ *(it - 1) };
      return cp <= r.last ? r.flags : 0;
    }

    struct text
    {
      std::vector<uint32_t> cps;
      std::vector<uint8_t> cls;
      std::vector<size_t> offsets;
    };

    text decode_utf8(std::string_view s)
    {
      text t;
      size_t i{};
      while(i < s.size())
      {
        auto const c{ static_cast<unsigned char>(s[i]) };
        uint32_t cp{ c };
        size_t len{ 1 };
        if(c >= 0xf0)
        {
          len = 4;
          cp = c & 0x07;
        }
        else if(c >= 0xe0)
        {
          len = 3;
          cp = c & 0x0f;
        }
        else if(c >= 0xc0)
        {
          len = 2;
          cp = c & 0x1f;
        }
        if(len > 1)
        {
          if(i + len > s.size())
          {
            len = 1;
            cp = c;
          }
          else
          {
            for(size_t k{ 1 }; k < len; ++k)
            {
              cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3f);
            }
          }
        }
        t.cps.push_back(cp);
        t.cls.push_back(classes(cp));
        t.offsets.push_back(i);
        i += len;
      }
      t.offsets.push_back(s.size());
      return t;
    }

    bool is_newline(uint32_t const cp)
    {
      return cp == '\r' || cp == '\n';
    }

    struct splitter
    {
      text const &t;
      size_t n;

      bool upper(size_t i) const { return t.cls[i] & (LU | LT | LM | LO | MARK); }
      bool lower(size_t i) const { return t.cls[i] & (LL | LM | LO | MARK); }
      bool prefix(size_t i) const { return !is_newline(t.cps[i]) && !(t.cls[i] & (LETTER | NUM)); }
      bool white(size_t i) const { return t.cls[i] & WHITE; }
      bool punct(size_t i) const { return !(t.cls[i] & (WHITE | LETTER | NUM)); }

      size_t contraction(size_t i) const
      {
        if(i >= n || t.cps[i] != '\'')
        {
          return i;
        }
        auto const at{ [&](size_t k) -> uint32_t {
          if(k >= n)
          {
            return 0;
          }
          auto const c{ t.cps[k] };
          return (c >= 'A' && c <= 'Z') ? c + 32 : c;
        } };
        auto const a{ at(i + 1) };
        auto const b{ at(i + 2) };
        if(a == 's' || a == 't' || a == 'm' || a == 'd')
        {
          return i + 2;
        }
        if((a == 'r' && b == 'e') || (a == 'v' && b == 'e') || (a == 'l' && b == 'l'))
        {
          return i + 3;
        }
        return i;
      }

      // Returns the end of the match at i (> i).
      size_t match(size_t const i) const
      {
        // 1: prefix? upper* lower+ contraction?
        for(int with_prefix{ 1 }; with_prefix >= 0; --with_prefix)
        {
          size_t j{ i };
          if(with_prefix)
          {
            if(!prefix(j))
            {
              continue;
            }
            ++j;
          }
          size_t a_end{ j };
          while(a_end < n && upper(a_end))
          {
            ++a_end;
          }
          for(size_t k{ a_end + 1 }; k-- > j;)
          {
            if(k < n && lower(k))
            {
              size_t e{ k };
              while(e < n && lower(e))
              {
                ++e;
              }
              return contraction(e);
            }
          }
        }
        // 2: prefix? upper+ lower* contraction?
        for(int with_prefix{ 1 }; with_prefix >= 0; --with_prefix)
        {
          size_t j{ i };
          if(with_prefix)
          {
            if(!prefix(j))
            {
              continue;
            }
            ++j;
          }
          size_t e{ j };
          while(e < n && upper(e))
          {
            ++e;
          }
          if(e == j)
          {
            continue;
          }
          while(e < n && lower(e))
          {
            ++e;
          }
          return contraction(e);
        }
        // 3: numbers, up to 3
        if(t.cls[i] & NUM)
        {
          size_t e{ i };
          while(e < n && e - i < 3 && (t.cls[e] & NUM))
          {
            ++e;
          }
          return e;
        }
        // 4: ' '? punct+ [\r\n/]*
        for(int with_space{ 1 }; with_space >= 0; --with_space)
        {
          size_t j{ i };
          if(with_space)
          {
            if(t.cps[j] != ' ')
            {
              continue;
            }
            ++j;
          }
          if(j < n && punct(j))
          {
            size_t e{ j };
            while(e < n && punct(e))
            {
              ++e;
            }
            while(e < n && (is_newline(t.cps[e]) || t.cps[e] == '/'))
            {
              ++e;
            }
            return e;
          }
        }
        if(white(i))
        {
          size_t w_end{ i };
          while(w_end < n && white(w_end))
          {
            ++w_end;
          }
          // 5: \s*[\r\n]+
          for(size_t k{ w_end }; k-- > i;)
          {
            if(is_newline(t.cps[k]))
            {
              return k + 1;
            }
          }
          // 6: \s+(?!\S)
          if(w_end == n)
          {
            return n;
          }
          if(w_end - i >= 2)
          {
            return w_end - 1;
          }
          // 7: \s+
          return w_end;
        }
        return i + 1;
      }
    };

    // GPT-2's byte-to-character mapping of byte-level BPE.
    struct byte_map
    {
      uint32_t to_char[256]{};
      std::unordered_map<uint32_t, uint8_t> to_byte;

      byte_map()
      {
        std::vector<bool> direct(256);
        for(int b{ '!' }; b <= '~'; ++b)
        {
          direct[static_cast<size_t>(b)] = true;
        }
        for(int b{ 0xa1 }; b <= 0xac; ++b)
        {
          direct[static_cast<size_t>(b)] = true;
        }
        for(int b{ 0xae }; b <= 0xff; ++b)
        {
          direct[static_cast<size_t>(b)] = true;
        }
        uint32_t extra{};
        for(int b{}; b < 256; ++b)
        {
          to_char[b] = direct[static_cast<size_t>(b)] ? static_cast<uint32_t>(b) : 256 + extra++;
          to_byte[to_char[b]] = static_cast<uint8_t>(b);
        }
      }
    };

    byte_map const &bytes()
    {
      static byte_map const map;
      return map;
    }

    void put_utf8(std::string &out, uint32_t const cp)
    {
      if(cp < 0x80)
      {
        out.push_back(static_cast<char>(cp));
      }
      else if(cp < 0x800)
      {
        out.push_back(static_cast<char>(0xc0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
      }
      else
      {
        out.push_back(static_cast<char>(0xe0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
      }
    }

    void encode_piece(tokenizer const &tok, std::string_view piece, std::vector<int32_t> &out)
    {
      auto const &bm{ bytes() };
      std::string mapped;
      std::vector<int32_t> symbols;
      for(unsigned char const c : piece)
      {
        std::string one;
        put_utf8(one, bm.to_char[c]);
        mapped += one;
        auto const it{ tok.ids.find(one) };
        symbols.push_back(it == tok.ids.end() ? -1 : it->second);
      }
      if(tok.ignore_merges)
      {
        if(auto const it{ tok.ids.find(mapped) }; it != tok.ids.end())
        {
          out.push_back(it->second);
          return;
        }
      }
      while(symbols.size() > 1)
      {
        uint64_t best{ UINT64_MAX };
        size_t at{};
        for(size_t i{}; i + 1 < symbols.size(); ++i)
        {
          if(symbols[i] < 0 || symbols[i + 1] < 0)
          {
            continue;
          }
          auto const key{ (static_cast<uint64_t>(symbols[i]) << 32) | static_cast<uint32_t>(symbols[i + 1]) };
          if(auto const it{ tok.merges.find(key) }; it != tok.merges.end() && it->second < best)
          {
            best = it->second;
            at = i;
          }
        }
        if(best == UINT64_MAX)
        {
          break;
        }
        symbols[at] = static_cast<int32_t>(best & 0xffffffffu);
        symbols.erase(symbols.begin() + static_cast<ptrdiff_t>(at) + 1);
      }
      for(auto const s : symbols)
      {
        if(s >= 0)
        {
          out.push_back(s);
        }
      }
    }

    void encode_text(tokenizer const &tok, std::string_view s, std::vector<int32_t> &out)
    {
      if(s.empty())
      {
        return;
      }
      auto const t{ decode_utf8(s) };
      splitter const sp{ t, t.cps.size() };
      size_t i{};
      while(i < sp.n)
      {
        auto const e{ sp.match(i) };
        encode_piece(tok, s.substr(t.offsets[i], t.offsets[e] - t.offsets[i]), out);
        i = e;
      }
    }
  }

  void load_tokenizer(model &m)
  {
    auto const f{ m.files.find("tokenizer.json") };
    if(f == m.files.end())
    {
      fail(m.path + " has no tokenizer.json");
    }
    auto const root{ json::parse(f->second) };
    auto &tok{ m.tok };
    auto const &bpe{ root.at("model") };
    if(bpe.at("type").str() != "BPE")
    {
      fail("unsupported tokenizer model " + bpe.at("type").str());
    }
    tok.ignore_merges = bpe.get("ignore_merges") && bpe.at("ignore_merges").boolean_or(false);
    int32_t max_id{};
    for(auto const &[piece, id] : bpe.at("vocab").fields())
    {
      auto const i{ static_cast<int32_t>(id.integer()) };
      tok.ids.emplace(piece, i);
      max_id = std::max(max_id, i);
    }
    for(auto const &a : root.at("added_tokens").items())
    {
      auto const i{ static_cast<int32_t>(a.at("id").integer()) };
      auto const &content{ a.at("content").str() };
      tok.ids.emplace(content, i);
      tok.specials.emplace_back(content, i);
      max_id = std::max(max_id, i);
    }
    tok.pieces.resize(static_cast<size_t>(max_id) + 1);
    tok.special.resize(static_cast<size_t>(max_id) + 1);
    for(auto const &[piece, id] : tok.ids)
    {
      tok.pieces[static_cast<size_t>(id)] = piece;
    }
    for(auto const &[piece, id] : tok.specials)
    {
      tok.special[static_cast<size_t>(id)] = true;
    }
    // Longest first, so a special token that starts another isn't matched early.
    std::sort(tok.specials.begin(), tok.specials.end(), [](auto const &a, auto const &b) {
      return a.first.size() > b.first.size();
    });
    auto const &merges{ bpe.at("merges").items() };
    tok.merges.reserve(merges.size());
    for(size_t rank{}; rank < merges.size(); ++rank)
    {
      std::string left, right;
      auto const &mg{ merges[rank] };
      if(mg.is_array())
      {
        left = mg.items().at(0).str();
        right = mg.items().at(1).str();
      }
      else
      {
        auto const &s{ mg.str() };
        auto const space{ s.find(' ') };
        left = s.substr(0, space);
        right = s.substr(space + 1);
      }
      auto const l{ tok.ids.find(left) };
      auto const r{ tok.ids.find(right) };
      auto const merged{ tok.ids.find(left + right) };
      if(l == tok.ids.end() || r == tok.ids.end() || merged == tok.ids.end())
      {
        continue;
      }
      auto const key{ (static_cast<uint64_t>(l->second) << 32) | static_cast<uint32_t>(r->second) };
      tok.merges.emplace(key, (static_cast<uint64_t>(rank) << 32) | static_cast<uint32_t>(merged->second));
    }
  }

  std::vector<int32_t> tokenize(model const &m, std::string_view s, bool const special)
  {
    std::vector<int32_t> out;
    auto const &tok{ m.tok };
    if(!special)
    {
      encode_text(tok, s, out);
      return out;
    }
    size_t start{};
    size_t i{};
    while(i < s.size())
    {
      if(s[i] == '<')
      {
        bool found{};
        for(auto const &[piece, id] : tok.specials)
        {
          if(s.compare(i, piece.size(), piece) == 0)
          {
            encode_text(tok, s.substr(start, i - start), out);
            out.push_back(id);
            i += piece.size();
            start = i;
            found = true;
            break;
          }
        }
        if(found)
        {
          continue;
        }
      }
      ++i;
    }
    encode_text(tok, s.substr(start), out);
    return out;
  }

  std::string detokenize(model const &m, int32_t const *ids, size_t const n)
  {
    auto const &tok{ m.tok };
    auto const &bm{ bytes() };
    std::string out;
    for(size_t k{}; k < n; ++k)
    {
      auto const id{ ids[k] };
      if(id < 0 || static_cast<size_t>(id) >= tok.pieces.size())
      {
        continue;
      }
      auto const &piece{ tok.pieces[static_cast<size_t>(id)] };
      if(tok.special[static_cast<size_t>(id)])
      {
        out += piece;
        continue;
      }
      auto const t{ decode_utf8(piece) };
      for(auto const cp : t.cps)
      {
        if(auto const it{ bm.to_byte.find(cp) }; it != bm.to_byte.end())
        {
          out.push_back(static_cast<char>(it->second));
        }
      }
    }
    return out;
  }

  std::string detokenize(model const &m, std::vector<int32_t> const &ids)
  {
    return detokenize(m, ids.data(), ids.size());
  }

  int32_t token_id(model const &m, std::string_view const piece)
  {
    auto const it{ m.tok.ids.find(std::string{ piece }) };
    return it == m.tok.ids.end() ? -1 : it->second;
  }
}
