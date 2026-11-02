package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"sync"
	"time"

	"github.com/bradfitz/gomemcache/memcache"
)

const (
	cacheTTLSeconds = 300
	indexVersionKey = "version:index"
)

// userCache はログイン中のユーザーを保持する。
// セッションの判定はdel_flgを見ないので、BANで内容が古くなっても動作は変わらない。
var userCache sync.Map

func clearCaches() {
	userCache.Clear()
	if err := memcacheClient.DeleteAll(); err != nil {
		log.Print(err)
	}
}

func cachedUser(ctx context.Context, uid any) (User, error) {
	key := fmt.Sprint(uid)
	if u, ok := userCache.Load(key); ok {
		return u.(User), nil
	}

	u := User{}
	err := db.GetContext(ctx, &u, "SELECT * FROM `users` WHERE `id` = ?", uid)
	if err != nil {
		return User{}, err
	}
	userCache.Store(key, u)
	return u, nil
}

// キャッシュのキーにバージョンを含めて、更新のたびにバージョンを変える。
// 更新と同時に読み込んだ処理が古い値を書き戻しても、古いキーに入るだけで読まれない。
func cacheVersions(keys []string) map[string]string {
	versions := make(map[string]string, len(keys))
	items, err := memcacheClient.GetMulti(keys)
	if err != nil {
		log.Print(err)
	}
	for _, key := range keys {
		versions[key] = "0"
		if item, ok := items[key]; ok {
			versions[key] = string(item.Value)
		}
	}
	return versions
}

func bumpCacheVersion(key string) {
	value := strconv.FormatInt(time.Now().UnixNano(), 36)
	err := memcacheClient.Set(&memcache.Item{Key: key, Value: []byte(value)})
	if err != nil {
		log.Print(err)
	}
}

func setCache(key string, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		log.Print(err)
		return
	}
	err = memcacheClient.Set(&memcache.Item{Key: key, Value: data, Expiration: cacheTTLSeconds})
	if err != nil {
		log.Print(err)
	}
}

func cachedIndexPosts(ctx context.Context) ([]Post, error) {
	version := cacheVersions([]string{indexVersionKey})[indexVersionKey]
	key := "index:" + version

	if item, err := memcacheClient.Get(key); err == nil {
		posts := []Post{}
		if err := json.Unmarshal(item.Value, &posts); err == nil {
			return posts, nil
		}
	}

	posts, err := selectPosts(ctx, "idx_posts_created", "")
	if err != nil {
		return nil, err
	}
	setCache(key, posts)
	return posts, nil
}

type postComments struct {
	Count    int
	Comments []Comment
}

func commentVersionKey(postID int) string {
	return "version:post:" + strconv.Itoa(postID)
}

// cachedPostComments は一覧用のコメントを、なかった投稿の分だけDBから取得する
func cachedPostComments(ctx context.Context, postIDs []int) (map[int]postComments, error) {
	versionKeys := make([]string, len(postIDs))
	for i, id := range postIDs {
		versionKeys[i] = commentVersionKey(id)
	}
	versions := cacheVersions(versionKeys)

	cacheKeys := make(map[int]string, len(postIDs))
	keys := make([]string, 0, len(postIDs))
	for _, id := range postIDs {
		key := "comments:" + strconv.Itoa(id) + ":" + versions[commentVersionKey(id)]
		cacheKeys[id] = key
		keys = append(keys, key)
	}
	items, err := memcacheClient.GetMulti(keys)
	if err != nil {
		log.Print(err)
	}

	result := make(map[int]postComments, len(postIDs))
	missed := []int{}
	for _, id := range postIDs {
		item, ok := items[cacheKeys[id]]
		value := postComments{}
		if ok && json.Unmarshal(item.Value, &value) == nil {
			result[id] = value
		} else {
			missed = append(missed, id)
		}
	}
	if len(missed) == 0 {
		return result, nil
	}

	fetched, err := fetchPostComments(ctx, missed, false)
	if err != nil {
		return nil, err
	}
	for _, id := range missed {
		result[id] = fetched[id]
		setCache(cacheKeys[id], fetched[id])
	}
	return result, nil
}
