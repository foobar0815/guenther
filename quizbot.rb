#!/usr/bin/env ruby

require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'yaml'

class Guenther
  CONFIG_FILE = 'guenther.yaml'.freeze
  HELP_TEXT = <<EOT.freeze
Usage:
  startquiz <number of questions>: start a quiz
  next: move to the next question
  scoreboard: show the last score board
  exit: exit
  help: show this help text
EOT

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
      STDERR.puts 'Usage: {$PROGRAM_NAME} <jid> <password> <room@conference.example.com/nick>'
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
          linesplit = line.split(': ', 2)
          cur_question[linesplit.first.strip] = linesplit.last.strip
        end
      end
    end
  end

  def ask_question
    @current_question = @questions.sample
    @current_question['lifetime'] = Time.now + 60
    say @current_question['Question']
    @remaining_questions -= 1
  end

  def handle_answer(nick, text)
    regex = @current_question['Regexp']
    answered = if regex
                 # Compare answer to the regex if we have one
                 /#{regex}/ =~ text
               else
                 text.casecmp(@current_question['Answer']) == 0
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

  def start_quiz(parameter)
    number_of_questions = parameter.to_i
    # Handle not well formed parameter
    if number_of_questions == 0
      say "Invalid number of questions: #{parameter}"
      return
    end

    @scoreboard.clear
    @remaining_questions = number_of_questions
    ask_question

    # Thread to handle question timeouts
    Thread.new do
      while @current_question
        sleep 1 while Time.now < @current_question['lifetime']
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
        say 'No more questions'
        say_scoreboard
      else
        ask_question
      end
    else
      say 'No quiz has been started!'
    end
  end

  def run
    Jabber.debug = true

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
      handle_answer nick, text if @current_question

      # Nothing to do if the line is not addressed to us
      next unless talking_to_me? text

      command, parameter = extract_command(text)

      case command
      when 'startquiz'
        start_quiz parameter
      when 'next'
        handle_next
      when 'scoreboard'
        say_scoreboard
      when 'exit'
        @muc_client.exit "Exiting on behalf of #{nick}"
        mainthread.wakeup
      when 'help'
        say HELP_TEXT
      else
        say 'Unknown command, try help'
      end
    end

    Thread.stop
    client.close
  end
end

if __FILE__ == $PROGRAM_NAME
  guenther = Guenther.new
  guenther.load_questions
  guenther.run
end
