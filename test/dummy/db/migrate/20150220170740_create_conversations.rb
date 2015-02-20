class CreateConversations < ActiveRecord::Migration
  def change
    create_table :conversations do |t|
      t.string :state_machine
      t.string :subject
      t.boolean :closed

      t.timestamps
    end
  end
end
