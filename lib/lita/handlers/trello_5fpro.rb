require "lita"
require 'trello'

module Lita
  module Handlers
    class Trello5fpro < Handler
      config :scopes, type: Hash
      config :public_key, type: String
      config :secret_key, type: String
      config :member_token, type: String

      on :connected, :init_trello

      route(/^tro\s+today$/, :today_chat, :help => {
        "tro today" => "觀看每個人今天要做的"
      })
      def today_chat(response)
        response.reply "今天要做的票....(計算中)"
        response.reply today.join("\n")
      end

      http.get "/5fpro/today", :today_http
      def today_http(request, response)
        response.body << today.join("\n")
      end

      def today
        init_trello
        members = {}
        msgs = []
        fetch_scoped_boards.each do |b|
          list = b.lists(:filter => :open).select{ |l| l.name == "今天要做"}.first
          next unless list
          list.cards.each do |c|
            c.member_ids.each do |mid|
              members[mid] ||= {}
              members[mid][b.name] ||= []
              members[mid][b.name] << c
            end
          end
        end
        members.each do |mid, tmps|
          member = Trello::Member.find mid
          next unless member
          msgs << member.full_name
          tmps.each do |board_name, cards|
            cards.each do |c|
              msgs << "#{board_name} - ##{c.short_id} #{c.name} #{c.url}"
            end
          end
          msgs << "-----------------------------"
        end
        return msgs
      end

      route(/^note\s*([^ ]*)\s*([^ ]*)/i, :note_chat, :help => {
        "note BOARD FORMAT" => "取得 release note 內容, FORMAT:[trello,text], def: trello"
      })
      def note_chat(response)
        init_with_scope(response)
        response.reply "本週 release note 整理中, 請稍後..."
        format = @args[0]
        format = 'trello' if format != 'text'
        response.reply note(format)
      end

      http.get "/5fpro/note", :note_http
      def note_http(request, response)
        @scope = request.params["scope"].to_sym
        @format = request.params["format"] || 'trello'
        response.body << note(@format)
      end

      def note(format)
        init_trello
        b = Trello::Board.find(board_id)
        generate_release_note(fetch_cards_by_lists(b, released_lists(b)), format)
      end

      route(/^score\s+(.+)/i, :score_chat, :help => {
        "score BOARD" => "計算每人得分, score all 則是全部加總"
      })
      def score_chat(response)
        @scope = response.matches[0][0]
        response.reply "計算中, 請稍等"
        response.reply score(@scope).join("\n")
      end

      http.get "/5fpro/score", :score_http

      def score_http(request, response)
        @scope = request.params[:board]
        response.body << score(@scope).join("\n")
      end

      def score(scope_name)
        init_trello
        msgs = []
        if scope_name.to_s == "all"
          cards = []
          fetch_scoped_boards.each do |b|
            cards += fetch_cards_by_lists(b, runing_lists(b))
          end
          msgs << "** 全部總分 **"
          msgs << generate_scores(cards)
          msgs << "-----------------------"
          msgs << "** 已做完總分 **"
          cards = []
          fetch_scoped_boards.each do |b|
            cards += fetch_cards_by_lists(b, released_lists(b))
          end
          msgs << generate_scores(cards)
        else
          if b = Trello::Board.find(board_id)
            cards = fetch_cards_by_lists(b, released_lists(b))
            msgs << generate_scores(cards)
          end
        end

        msgs
      end

      route(/^report\s*([^ ]*)/i, :report_chat, :help => {
        "report BOARD" => "依專案列出上週與下週工作"
      })
      def report_chat(response)
        response.reply "報告生成中..."
        init_with_scope(response)
        text = report(board_id)
        response.reply text
      end

      http.get "/5fpro/report", :report_http
      def report_http(request, response)
        @scope = request.params["scope"].to_sym
        response.body << report(board_id)
      end

      def report(bid)
        init_trello
        b = Trello::Board.find(bid)
        current_cards = fetch_cards_by_lists(b, released_lists(b))
        next_cards = fetch_cards_by_lists(b, next_lists(b))
        data = insert_report_data({}, :current, current_cards)
        data = insert_report_data(data, :next, next_cards)
        strs = []
        data.keys.sort_by{ |p| p }.each do |project|
          tmps = data[project]
          strs << "##{project}"
          strs << "上週:"
          (tmps[:current] || []).each do |card|
            score = parse_score(card)
            # name = card_name_without_score(card, score).gsub("#{project} - ", "")
            strs << "- #{format_trello_output(card)}"
          end
          strs << "本週:"
          (tmps[:next] || []).each do |card|
            score = parse_score(card)
            # name = card_name_without_score(card, score).gsub("#{project} - ", "")
            strs << "- #{format_trello_output(card)}"
          end
          strs << "\n----------------------------------------\n"
        end
        return strs.join("\n")
      end

      def init_trello(res = nil)
        Trello.configure do |config|
          config.developer_public_key = options(:public_key)
          config.member_token = options(:member_token)
        end
      end

      private

      def init_with_scope(response)
        @scope = response.matches[0][0].to_sym
        @args = response.matches[0][1..-1]
      end

      def insert_report_data(data, key, cards)
        cards.each do |c|
          proj = parse_project(c)
          data[proj] ||= {}
          data[proj][key] ||= []
          data[proj][key] << c
        end
        return data
      end

      def fetch_cards_by_lists(board, lists)
        cards = []
        board.lists(:filter => :open).each do |l|
          if lists.include?(l.name)
            l.cards(:filter => :open).each{ |c| cards << c }
          end
        end
        return cards
      end

      def fetch_scoped_boards
        options(:scopes).map do |scope, tmps|
          Trello::Board.find(tmps[:board_id])
        end
      end

      def generate_scores(cards)
        scores = {}
        cards.each do |c|
          score = parse_score(c)
          # score = (score / c.member_ids.size).to_i rescue 0
          score = 0 unless score > 0
          c.member_ids.each do |member_id|
            user = fetch_member_name(member_id)
            scores[user] ||= 0
            scores[user] += score
          end
        end
        scores.map{ |u, s| "#{u}: #{s}" }.join("\n")
      end

      def generate_release_note(cards, format = 'trello')
        total = 0
        text = []
        trellos = []
        sorted_by_project(cards).each do |c|
          score = parse_score(c)
          total += score
          text << "* #{card_name_without_score(c, score)} #{c.url}"
          trellos << format_trello_output(c)
        end
        if format.to_s == 'trello'
          trellos.join("\n") + "\n total: #{total}\n"
        else
          return text.join("\n")
        end
      end

      def format_trello_output(card)
        "#{card.url}"
      end

      def sorted_by_project(cards)
        cards.sort_by{ |c| parse_project(c) }
      end

      def card_name_without_score(card, score)
        card.name.gsub("[#{score}] ", "").gsub("[#{score}]", "")
      end

      def parse_score(card)
        tmps = card.name.scan(/(\[([0-9]+)\][ ]*)/)[0]
        return tmps[1].to_i rescue 0
      end

      def parse_project(card, score = nil)
        score ||= parse_score(card)
        tmps = card.name.split(" - ")
        if tmps.size > 1
          return tmps.first.gsub("[#{score}] ", "").gsub("[#{score}]", "")
        end
        return ""
      end

      def options(key)
        Lita.config.handlers.trello5fpro.send(key)
      end

      def board_id
        options(:scopes)[@scope.to_s.to_sym][:board_id]
      end

      def released_lists(b)
        options(:scopes).each do |scope, tmps|
          return options(:scopes)[scope][:released_lists] if b.url.index(tmps[:board_id])
        end
      end

      def next_lists(b)
        options(:scopes).each do |scope, tmps|
          return options(:scopes)[scope][:next_lists] if b.url.index(tmps[:board_id])
        end
      end

      def runing_lists(b)
        options(:scopes).each do |scope, tmps|
          board_hash = options(:scopes)[scope]
          return board_hash[:released_lists] + board_hash[:next_lists] if b.url.index(tmps[:board_id])
        end
      end

      def fetch_member_name(member_id)
        @members ||= {}
        @members[member_id] ||= Trello::Member.find(member_id).username
        @members[member_id]
      end

    end

    Lita.register_handler(Trello5fpro)
  end
end
