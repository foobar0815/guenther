#!/usr/bin/env ruby

require 'optparse'
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'yaml'

# Guenther's runtime configuration
class Configuration
  attr_accessor :category
  attr_reader :debug

  def initialize
    @category = 'all'
    @debug = false
  end

  def to_s
    inspect
  end

  def debug=(value)
    @debug = value
    Jabber.debug = @debug
  end
end

# The main class implementing the XMPP quiz bot
class Guenther
  CONFIG_FILE = 'guenther.yaml'.freeze # move to Configuration
  HELP_TEXT = <<EOT.freeze
Usage:
  startquiz <number of questions> [category|all]: start a quiz
  stopquiz: stops the current quiz
  next: move to the next question
  scoreboard: show the last score board
  categories: show all available categories
  config: show the current config
  set: set a config value
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
    @config = Configuration.new
    @questions = []
    @current_question = nil
    @remaining_questions = 0
    @scoreboard = Hash.new(0)

    return if try_load_config

    parse_options
  end

  def parse_options
    optparse = OptionParser.new do |opts|
      opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

      opts.on('-j', '--jid JID', 'Jabber identifier') do |j|
        @jid = j
      end

      opts.on('-p', '--password PASSWORD', 'Password') do |p|
        @password = p
      end

      opts.on('-r', '--room ROOM',
              'Multi-user chat room (room@conference.example.com/nick)') do |r|
        @room = r
      end

      opts.on('-d', '--debug', 'Enables XMPP debug logging') do
        @config.debug = true
      end

      opts.on('-h', '--help', 'Prints this help message') do
        puts opts
        exit 1
      end
    end

    begin
      optparse.parse!
      # TODO: Look at this, will it point out the missing argument?
      raise OptionParser::MissingArgument unless @jid
      raise OptionParser::MissingArgument unless @password
      raise OptionParser::MissingArgument unless @room
    rescue
      puts optparse
      exit 1
    end
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
    questions = if @config.category == 'all'
                  @questions
                else
                  @questions.select { |q| q['Category'] == @config.category }
                end
    @current_question = questions.sample
    @current_question['lifetime'] = Time.now + 60
    if @current_question['Category']
      say "[#{@current_question['Category']}] #{@current_question['Question']}"
    else
      say @current_question['Question']
    end
  end

  def answer_question
    regex = @current_question['Regexp']
    say regex if regex && @config.debug
    say @current_question['Answer'].delete('#')
  end

  def handle_answer(nick, text)
    regex = @current_question['Regexp']
    answered = if regex
                 # Compare answer to the regex if we have one
                 /#{regex}/i =~ text
               else
                 text.casecmp(@current_question['Answer'].delete('#')) == 0
               end

    if answered
      say "Correct answer #{nick}!"
      @scoreboard[nick] += 1
      @remaining_questions -= 1
      if @remaining_questions > 0
        ask_question
      else
        stop_quiz
      end
    end
  end

  def handle_categories
    count_per_category = Hash.new(0)
    @questions.each do |q|
      c = q['Category']
      count_per_category[c] += 1 if c
    end

    # Sort the above hash by key, this turns it into an array of arrays.
    # Map the outer array to an array of strings and join them with a comma.
    say count_per_category.sort.map { |e| "#{e[0]} (#{e[1]})" }.join(', ')
  end

  def say_scoreboard
    scoreboard = "(.•ˆ•… Scoreboard …•ˆ•.)"
    @scoreboard.each do |nick, score|
      scoreboard += "\n#{nick}: #{score}"
    end
    say scoreboard
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
    if @current_question
      say 'Quiz already running'
      return
    end

    matches = parameter.match(/(\d+)? ?(\S+)?/)
    number_of_questions = matches[1].to_i
    category = matches[2]

    # Handle not well formed parameter
    if number_of_questions == 0
      say "Invalid number of questions: #{matches[1]}"
      return
    end
    @remaining_questions = number_of_questions

    return unless set_category(category)

    @scoreboard.clear
    ask_question

    # Thread to handle question timeouts
    Thread.new do
      while @current_question
        # XXX this crashes at the end of the quiz because @current_question
        # will be set to nil
        sleep 1 while Time.now < @current_question['lifetime']
        answer_question
        ask_question
      end
    end
  end

  def stop_quiz
    if @current_question
      say_scoreboard
      @current_question = nil
    else
      say 'No quiz is running'
    end
  end

  def say(text)
    @muc_client.say text
  end

  def handle_next
    if @current_question
      answer_question
      ask_question
    else
      say 'No quiz is running'
    end
  end

  def say_config
    say @config.to_s
  end

  def set_category(value)
    unless value == 'all' || @questions.any? { |q| q['Category'] == value }
      say "Could not find any questions in category #{value}"
      return false
    end
    @config.category = value
    true
  end

  def handle_set(parameter)
    matches = parameter.match(/(\S+) (\S+)/)
    option = matches[1]
    value = matches[2]

    case option
    when 'category'
      set_category value
    when 'debug'
      @config.debug = value == 'true'
    else
      say 'Unknown option'
    end
  end

  def run
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

      # Look at every line if we have a question in flight and we
      # didn't say it
      handle_answer nick, text if @current_question && nick != me

      # Nothing to do if the line is not addressed to us
      next unless talking_to_me? text

      command, parameter = extract_command(text)

      case command
      when 'startquiz'
        start_quiz parameter
      when 'stopquiz'
        stop_quiz
      when 'next'
        handle_next
      when 'scoreboard'
        say_scoreboard
      when 'categories'
        handle_categories
      when 'config'
        say_config
      when 'set'
        handle_set parameter
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
