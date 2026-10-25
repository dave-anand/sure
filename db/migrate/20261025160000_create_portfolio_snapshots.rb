class CreatePortfolioSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :portfolio_snapshot_connections, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :account, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :source, null: false, limit: 100
      t.string :source_account_id, null: false, limit: 255
      t.date :last_snapshot_on
      t.jsonb :security_mappings, null: false, default: {}
      t.timestamps
    end
    add_index :portfolio_snapshot_connections, [ :family_id, :source, :source_account_id ],
      unique: true, name: "idx_portfolio_snapshot_source_identity"

    create_table :portfolio_snapshots, id: :uuid do |t|
      t.references :portfolio_snapshot_connection, type: :uuid, null: false, foreign_key: true,
        index: { name: "idx_portfolio_snapshots_connection" }
      t.date :as_of, null: false
      t.string :checksum, null: false, limit: 64
      t.jsonb :payload, null: false
      t.timestamps
    end
    add_index :portfolio_snapshots, [ :portfolio_snapshot_connection_id, :as_of ],
      unique: true, name: "idx_portfolio_snapshots_connection_date"

    reversible do |direction|
      direction.down do
        if select_value("SELECT EXISTS (SELECT 1 FROM portfolio_snapshot_connections)")
          raise ActiveRecord::IrreversibleMigration, "Published snapshot connections require a reviewed retention plan before rollback"
        end
      end
    end
  end
end
