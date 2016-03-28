require 'minitest/autorun'
require "#{__dir__}/quizbot"

class TestQuestionpool < Minitest::Unit::TestCase
  def setup
    @questionpool = Questionpool.new
    # Load our actual questions as fixtures
    @questionpool.load
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
end
