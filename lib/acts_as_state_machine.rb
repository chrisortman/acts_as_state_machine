module ActsAsStateMachine              #:nodoc:
  extend ActiveSupport::Concern

  class InvalidState < Exception #:nodoc:
  end
  class NoInitialState < Exception #:nodoc:
  end

  included do
  end

  module SupportingClasses
    class State
      attr_reader :name

      def initialize(name, opts)
        @name, @opts = name, opts 
      end

      def entering(record)
        enteract = @opts[:enter]
        record.send(:run_transition_action, enteract) if enteract
      end

      def entered(record)
        afteractions = @opts[:after]
        return unless afteractions
        Array(afteractions).each do |afteract|
          record.send(:run_transition_action, afteract)
        end
      end

      def exited(record)
        exitact  = @opts[:exit]
        record.send(:run_transition_action, exitact) if exitact
      end

    end

    class StateTransition
      attr_reader :from, :to, :opts

      def initialize(opts)
        @from, @to, @guard = opts[:from], opts[:to], opts[:guard]
        @opts = opts

      end

      def guard(obj)
        obj.valid? && (@guard ? obj.send(:run_transition_action, @guard) : true)
      end

      def perform(record)
        return false unless guard(record)
        loopback = record.current_state == to
        states = record.class.states
        next_state = states[to]
        old_state = states[record.current_state]

        update_timestamps(record, old_state) if record.class.record_state_timestamps == true

        next_state.entering(record) unless loopback

        record.update_attribute(record.class.state_column, to.to_s)

        next_state.entered(record) unless loopback
        old_state.exited(record) unless loopback
        true
      end

      def ==(obj)
        @from == obj.from && @to == obj.to
      end

      def update_timestamps(record, exiting_state) #:nodoc:
        t = record.class.default_timezone == :utc ? Time.now.utc : Time.now
        record.write_attribute("#{exiting_state.name}_created_at", t) if record.respond_to?("#{exiting_state.name}_created_at") && record.read_attribute("#{exiting_state.name}_created_at").nil?
        record.write_attribute("#{exiting_state.name}_created_on", t) if record.respond_to?("#{exiting_state.name}_created_on") && record.read_attribute("#{exiting_state.name}_created_on").nil?
        record.write_attribute("#{exiting_state.name}_updated_at", t) if record.respond_to?("#{exiting_state.name}_updated_at")
        record.write_attribute("#{exiting_state.name}_updated_on", t) if record.respond_to?("#{exiting_state.name}_updated_on")
      end
    end

    class Event
      attr_reader :name
      attr_reader :transitions
      attr_reader :opts
      attr_reader :klass

      def initialize(name, opts, transition_table, klass, &block)
        @name = name.to_sym
        @klass = klass
        @transitions = transition_table[@name] = []
        instance_eval(&block) if block
        @opts = opts
        @opts.freeze
        @transitions.freeze
        freeze
      end

      def next_states(record)
        @transitions.select { |t| t.from == record.current_state }
      end

      def fire(record)
        next_states(record).each do |transition|
          break true if transition.perform(record)
        end.present?
      end

      def transitions(trans_opts, &block)
        Array(trans_opts[:from]).each do |s|
          @transitions << SupportingClasses::StateTransition.new(trans_opts.merge({:from => s.to_sym}))
          if block
            # create a proxy object
            vh = SupportingClasses::ValidationHelper.new(@klass, @name ,trans_opts[:from])
            block.call(vh)
          end
        end
      end
    end

    # If you've found yourself here, either be prepared for some metaprogramming or accept the magic that is ruby (boo).
    # ValidationHelper is a proxy class, which gets instantiated when there's a block in a state transition.
    # Any method (hopefully a validation helper) called on the object for that block will get passed to the ValidationHelper object's 
    # method_missing method, which will modify the options to include an :if => 'state is current state AND :if you sent', and then 
    # call the missing method (again, hopefully a validation helper) with the altered options 

    class ValidationHelper
      attr_reader :klass, :transition, :state
      def initialize(klass, transition, state = nil)
        @klass = klass
        @transition = transition
        @state = state
      end

      # 11/10/08 Modified what gets passed to the validation so it includes the :if proc normally used in validation

      def method_missing(method, *args)
        proc = args.last[:if] unless args.nil? || args.last.class != Hash
        if @state.nil?
          configuration = args.extract_options!
          configuration.update({:if => Proc.new{|u| !u.current_state.nil? && u.current_state == @state && ( proc.nil? || proc.call(u) )}})
          args.push(configuration)
          @klass.send(method, *args)
        else
          configuration = args.extract_options!
          configuration.update({:if => Proc.new{|u| !u.current_state.nil? && !u.current_transition.nil?  && u.current_state == @state && u.current_transition == @transition  && ( proc.nil? || proc.call(u) )}})
          args.push(configuration)
          @klass.send(method, *args)
        end
      end
    end

  end

  module InstanceMethods
    def set_initial_state #:nodoc:
      write_attribute self.class.state_column, self.class.initial_state.to_s if read_attribute(self.class.state_column).nil?
    end

    def run_initial_state_actions
      initial = self.class.states[self.class.initial_state.to_sym]
      initial.entering(self)
      initial.entered(self)
    end

    # Returns the current state the object is in, as a Ruby symbol.
    def current_state
      state = self.send(self.class.state_column)
      unless state.nil?
        state.to_sym
      end
    end

    def current_transition
      @transition
    end

    # Returns what the next state for a given event would be, as a Ruby symbol.
    def next_state_for_event(event)
      ns = next_states_for_event(event)
      ns.empty? ? nil : ns.first.to
    end

    def next_states_for_event(event)
      self.class.transition_table[event.to_sym].select do |s|
        s.from == current_state
      end
    end

    def run_transition_action(action)
      Symbol === action ? self.method(action).call : action.call(self)
    end
    private :run_transition_action
  end

  module ClassMethods

    # Configuration options are
    #
    # * +column+ - specifies the column name to use for keeping the state (default: state)
    # * +initial+ - specifies an initial state for newly created objects (required)
    def acts_as_state_machine(opts)

      raise NoInitialState unless opts[:initial]

      class_attribute :states
      class_attribute :initial_state
      class_attribute :transition_table
      class_attribute :event_table
      class_attribute :state_column
      class_attribute :record_state_timestamps

      self.states = {}
      self.initial_state = opts[:initial]
      self.transition_table = {}
      self.event_table = {}
      self.state_column = opts[:column] || 'state'
      record_timestamp = (opts[:record_state_timestamps] || opts[:record_state_timestamps].nil?) ? true : false
      self.record_state_timestamps = record_timestamp

      # cattr_reader  :initial_state
      # cattr_reader  :state_column
      # cattr_reader  :transition_table
      # cattr_reader  :event_table

      # Adding a named scope that allows objects to be searched by one or more states          
      scope(:in_state, lambda { |*qstates|

        raise InvalidState if (qstates - self.states.keys).size > 0
        where(self.state_column.to_sym => qstates)
      }) do
        def not_in_state(*args)
          raise "Can't use 'in_state' named_scope with 'not_in_state' named scope"
        end
      end

      scope(:not_in_state, lambda { |*states|

        raise InvalidState if (qstates - self.states.keys).size > 0
        where("#{self.state_column} NOT IN (?)",states)
      }) do
        def in_state(*args)
          raise "Can't use 'in_state' named_scope with 'not_in_state' named scope"
        end
      end

      before_create               :set_initial_state
      after_create                :run_initial_state_actions
    end

    # Returns an array of all known states.
    def states
      self.states.keys
    end

    # Define an event.  This takes a block which describes all valid transitions
    # for this event.
    #
    # Example:
    #
    # class Order < ActiveRecord::Base
    #   acts_as_state_machine :initial => :open
    #
    #   state :open
    #   state :closed
    #
    #   event :close_order do
    #     transitions :to => :closed, :from => :open
    #   end
    # end
    #
    # +transitions+ takes a hash where <tt>:to</tt> is the state to transition
    # to and <tt>:from</tt> is a state (or Array of states) from which this
    # event can be fired.
    #
    # This creates an instance method used for firing the event.  The method
    # created is the name of the event followed by an exclamation point (!).
    # Example: <tt>order.close_order!</tt>.
    def event(event, opts={}, &block)
      tt = self.transition_table

      et = self.event_table
      e = et[event.to_sym] = SupportingClasses::Event.new(event, opts, tt, self, &block)
      define_method("#{event.to_s}!") do
        @transition = event
        is_fired = e.fire(self)
        @transition = nil
        if self.changes[self.class.state_column]
          self.state = self.changes[self.class.state_column].first unless is_fired
        end
        is_fired
      end
    end

    # Define a state of the system. +state+ can take an optional Proc object
    # which will be executed every time the system transitions into that
    # state.  The proc will be passed the current object.
    #
    # Example:
    #
    # class Order < ActiveRecord::Base
    #   acts_as_state_machine :initial => :open
    #
    #   state :open
    #   state :closed, Proc.new { |o| Mailer.send_notice(o) }
    # end
    def state(name, opts={}, &block)
      state = SupportingClasses::State.new(name.to_sym, opts)
      self.states[name.to_sym] = state
      define_method("#{state.name}?") { current_state == state.name }

      if block
        vh = SupportingClasses::ValidationHelper.new(self, name.to_sym)
        block.call(vh)
      end
    end


  end
end
