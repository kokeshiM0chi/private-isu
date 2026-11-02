-- perf-02 db-index

-- コメント数の集計と、投稿ごとの新しいコメントの取得
CREATE INDEX idx_comments_post_created ON comments (post_id, created_at);
-- ユーザーページのコメント数の集計
CREATE INDEX idx_comments_user ON comments (user_id);
-- トップページと /posts の新着順
CREATE INDEX idx_posts_created ON posts (created_at);
-- ユーザーページの投稿一覧
CREATE INDEX idx_posts_user_created ON posts (user_id, created_at);
