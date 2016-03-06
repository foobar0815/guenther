#!/usr/bin/env ruby

require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'yaml'

class Guenther
  CONFIG_FILE = 'guenther.yaml'

  def try_load_config
    return false unless File.readable? CONFIG_FILE
    config = YAML.load_file(CONFIG_FILE)
    # config will be false if the file was empty
    return false unless config

    @jid = config['jid']
    @password = config['password']
    @room = config['room']
    true
  end

  def initialize
    @questions = []
    @current_question = nil
    @scoreboard = Hash.new(0)

    return if try_load_config

    if ARGV.size != 3
      STDERR.puts "Usage: #{$0} <jid> <password> <room@conference.example.com/nick>"
      exit 1
    end
    @jid = ARGV[0]
    @password = ARGV[1]
    @room = ARGV[2]
  end

  def load_questions
    cur_question = nil

    Dir.glob('quizdata/*.utf8') do |filename|
      File.open(filename).each_line do |line|
        next if line.start_with?('#')

        if line == "\n"
          if cur_question
            @questions.push(cur_question)
            cur_question = nil
          end
        else
          cur_question ||= {}
          linesplit = line.split(": ", 2)
          cur_question[linesplit.first.strip] = linesplit.last.strip
        end
      end
    end
  end

  def handle_answer(nick, text)
    if @current_question["Regexp"]
      if /#{@current_question["Regexp"]}/ =~ text
        answered = true
      end
    elsif text.casecmp(@current_question["Answer"]) == 0
      answered = true
    end

    if answered
      @muc_client.say("Correct answer #{nick}!")
      @scoreboard[nick] += 1
      if @current_question_count > 0
        @current_question = @questions.sample
        @current_question["lifetime"] = Time.now + 60
        @muc_client.say(@current_question["Question"])
        @current_question_count -= 1
      else
        @current_question = nil
        @muc_client.say("(.•ˆ•… Scoreboard …•ˆ•.)")
        @scoreboard.each do |key, val|
          @muc_client.say("#{key}: #{val}")
        end
      end
    end
  end

  def me
    @muc_client.jid.resource
  end
  def talking_to_me?(text)
    text.start_with? "#{me}:"
  end

  def extract_command(text)
    text.match(/^#{me}: (\S+) ?(.*)?/)[1..2]
  end

  def run
    Jabber::debug = true

    @client = Jabber::Client.new(Jabber::JID.new(@jid))
    @client.connect
    @client.auth(@password)
    @muc_client = Jabber::MUC::SimpleMUCClient.new(@client)
    @muc_client.join(@room)

    mainthread = Thread.current

    @muc_client.on_message do |time, nick, text|
      # Avoid reacting on messages delivered as room history
      next if time

      # look at every line if we have a question in flight
      if @current_question
        handle_answer nick, text
      end

      # Nothing to do if the line is not addressed to me
      next unless talking_to_me? text

      command, parameter = extract_command(text)

      # Bot: startquiz
      case command
      when "startquiz"
        # Handle not well formed parameter
        next if parameter.to_i == 0

        @current_question = @questions.sample
        @current_question["lifetime"] = Time.now + 60
        @muc_client.say(@current_question["Question"])
        Thread.new do
          while @current_question
            while Time.now < @current_question["lifetime"]
              sleep 1
            end
            @current_question = @questions.sample
            @current_question["lifetime"] = Time.now + 60
            @muc_client.say(@current_question["Question"])
          end
        end
        @current_question_count = parameter.to_i - 1
        @scoreboard.clear
      when "next"
        if @current_question
          @current_question = @questions.sample
          @current_question["lifetime"] = Time.now + 60
          @muc_client.say(@current_question["Question"])
        else
          @muc_client.say("No quiz has been started!")
        end
      when "exit"
        @muc_client.exit "Exiting on behalf of #{nick}"
        mainthread.wakeup
      end
    end

    Thread.stop

    @client.close
  end
end

if __FILE__ == $0
  guenther = Guenther.new
  guenther.load_questions
  guenther.run
end
