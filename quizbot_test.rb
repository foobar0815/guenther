require 'minitest/autorun'
require "#{__dir__}/quizbot"

class TestQuestionpool < Minitest::Unit::TestCase
  def setup
    @questionpool = Questionpool.new
    # Load our actual questions as fixtures
    @questionpool.load
  end

  def test_get
    questions = @questionpool.instance_variable_get(:@questions)
    assert questions.none? { |q| q['used'] }

    # Category Werkstoffe only contains one question
    question1 = @questionpool.get('de', 'Werkstoffe', 'all')
    assert_equal 'Kleister', question1['Answer']
    assert questions.one? { |q| q['used'] }

    question2 = @questionpool.get('de', 'Werkstoffe', 'all')
    # Assert that we get the same question again
    assert_same question1, question2
  end

  def test_load
    assert !@questionpool.instance_variable_get(:@questions).empty?
  end

  def test_any_key_has_value?
    assert @questionpool.any_key_has_value?('dontcare', 'all')
    assert @questionpool.any_key_has_value?('Category', 'Werkstoffe')
    assert !@questionpool.any_key_has_value?('NonExistingCategory', 'dontcare')
    assert !@questionpool.any_key_has_value?('Category', 'NonExisting')
  end

  def test_number_of_questions_per
    qp = Questionpool.new
    qp.instance_variable_set :@questions, [
      {'Category' => 'category1'}, {'Category' => 'category1'},
      { 'Category' => 'category2'}, {'Answer' => '42'},
    ]
    assert_equal "category1 (2), category2 (1)",
                 qp.number_of_questions_per('Category')
  end

  def test_reset_used_questions
    questions = [{'used' => false}, {'used' => true}]
    qp = Questionpool.new
    qp.instance_variable_set :@questions, questions

    assert questions.one? { |q| q['used'] }

    qp.send :reset_used_questions

    assert questions.none? { |q| q['used'] }
  end
end
