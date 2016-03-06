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
    @remaining_questions = 0
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

  def ask_question
    @current_question = @questions.sample
    @current_question["lifetime"] = Time.now + 60
    say @current_question["Question"]
    @remaining_questions -= 1
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
      say "Correct answer #{nick}!"
      @scoreboard[nick] += 1
      if @remaining_questions > 0
        ask_question
      else
        @current_question = nil
        say_scoreboard
      end
    end
  end

  def say_scoreboard
    say "(.•ˆ•… Scoreboard …•ˆ•.)"
    @scoreboard.each do |nick, score|
      say "#{nick}: #{score}"
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

  def start_quiz(number_of_questions)
    @scoreboard.clear
    @remaining_questions = number_of_questions
    ask_question

    # Thread to handle question timeouts
    Thread.new do
      while @current_question
        while Time.now < @current_question["lifetime"]
          sleep 1
        end
        ask_question
      end
    end
  end

  def say(text)
    @muc_client.say text
  end

  def handle_next
    if @current_question
      if @remaining_questions < 1
        @current_question = nil
        say "No more questions"
        say_scoreboard
      else
        ask_question
      end
    else
      say "No quiz has been started!"
    end
  end

  def run
    Jabber::debug = true

    jid = Jabber::JID.new(@jid)
    client = Jabber::Client.new(jid)
    client.connect
    client.auth(@password)
    @muc_client = Jabber::MUC::SimpleMUCClient.new(client)
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

      case command
      when "startquiz"
        number_of_questions = parameter.to_i
        # Handle not well formed parameter
        if number_of_questions == 0
          say "Invalid number of questions: #{parameter}"
          next
        end

        start_quiz number_of_questions
      when "next"
        handle_next
      when "scoreboard"
        say_scoreboard
      when "exit"
        @muc_client.exit "Exiting on behalf of #{nick}"
        mainthread.wakeup
      end
    end

    Thread.stop
    client.close
  end
end

if __FILE__ == $0
  guenther = Guenther.new
  guenther.load_questions
  guenther.run
end
