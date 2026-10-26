package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 红果内置；其余站源安装扩展后才可用。
func TestNativeBuildAuthorization(t *testing.T) {
	engine := sourceFixtureEngine(t, nil)
	for _, source := range []string{sourceHuangdou, sourceHuangguoVideo, sourceHuangguoAI, sourceCloudFront, sourceDSD} {
		installTestExtension(t, engine, source)
	}
	for _, source := range []string{sourceHongguo, sourceHuangdou, sourceHuangguoVideo, sourceHuangguoAI, sourceCloudFront, sourceDSD} {
		for _, action := range []string{"catalog", "cached", "sourceStatus", "sourceJob", "cancelSourceJob", "detail", "followCheck", "cover", "resolve", "enqueueDownloads", "localPlayback"} {
			input := nativeInput{Action: action, Source: source, Drama: nativeDrama{ID: source + ":123", Source: source}}
			if err := nativeAuthorizeInput(input); err != nil {
				t.Fatalf("%s %s: installed source rejected: %v", action, source, err)
			}
		}
	}
	if err := nativeAuthorizeInput(nativeInput{Action: "catalog", Source: "unknown", Drama: nativeDrama{ID: "unknown:123", Source: "unknown"}}); !errors.Is(err, errNativeBuildSource) {
		t.Fatalf("unknown source accepted: %v", err)
	}
	if err := nativeAuthorizeInput(nativeInput{Action: "catalog", Source: sourceYeguo, Drama: nativeDrama{ID: sourceYeguo + ":123", Source: sourceYeguo}}); !errors.Is(err, errNativeBuildSource) {
		t.Fatalf("uninstalled source accepted: %v", err)
	}
	for _, input := range []nativeInput{
		{Action: "resolve", Drama: nativeDrama{ID: "huangdou:123", Source: sourceHongguo}},
		{Action: "resolve", Drama: nativeDrama{ID: "hongguo:123", Source: sourceHongguo}, Chapter: Chapter{Source: sourceHuangdou}},
		{Action: "resolve", Drama: nativeDrama{ID: "hongguo:123", Source: sourceHongguo}, Chapter: Chapter{ID: "huangdou:123:1"}},
	} {
		if !errors.Is(nativeAuthorizeInput(input), errNativeBuildSource) {
			t.Fatal("mismatched source passed native authorization")
		}
	}
	manager := downloadTestManager(t)
	input := downloadTestInput(1)
	input.Entries[0].Chapter.Source = sourceHuangdou
	if _, err := manager.enqueue(input); !errors.Is(err, errNativeBuildSource) {
		t.Fatalf("mismatched download source accepted: %v", err)
	}
}

func TestNativeBuildPreservesForeignDownloadRecordsAndRestrictsScheduling(t *testing.T) {
	manager := downloadTestManager(t)
	for _, source := range []string{sourceHuangdou, sourceHuangguoVideo, sourceHuangguoAI, sourceCloudFront, sourceDSD} {
		installTestExtension(t, manager.engine, source)
	}
	records := []*nativeDownloadRecord{}
	for index, source := range []string{sourceHongguo, sourceHuangdou, sourceHuangguoVideo, sourceHuangguoAI, sourceCloudFront, sourceDSD} {
		drama := nativeDrama{ID: source + ":123", Source: source, Title: "合成下载"}
		record := &nativeDownloadRecord{nativeDownloadJob: nativeDownloadJob{
			ID: nativeDownloadID(drama.ID, 1), Drama: drama, Index: 1,
			Chapter: Chapter{ID: "1", Source: source, CurrentEpisode: json.RawMessage("1")}, State: "queued", Created: int64(index),
		}}
		records = append(records, record)
	}
	data, err := json.Marshal(records)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(manager.root, "index.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	reopened := newNativeDownloads(manager.engine)
	t.Cleanup(reopened.close)
	jobs, err := reopened.snapshot()
	if err != nil || len(jobs) != 6 {
		t.Fatalf("wrong visible downloads: %v, %v", jobs, err)
	}
	if len(reopened.jobs) != len(records) {
		t.Fatal("reopen discarded saved downloads")
	}
	started := make(chan string, 4)
	reopened.resolve = func(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
		started <- job.Drama.Source
		<-ctx.Done()
		return providerMedia{}, ctx.Err()
	}
	if err := reopened.control("", "resumeAll"); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for index := 0; index < 2; index++ {
		select {
		case source := <-started:
			seen[source] = true
		case <-time.After(5 * time.Second):
			t.Fatal("allowed download did not start")
		}
	}
	if !seen[sourceHongguo] && !seen[sourceHuangdou] {
		t.Fatalf("wrong sources scheduled: %v", seen)
	}
	if err := reopened.control("", "pauseAll"); err != nil {
		t.Fatal(err)
	}
	reopened.close()
	if job := reopened.jobs[nativeDownloadID(sourceDSD+":123", 1)]; job == nil {
		t.Fatal("DSD download was lost during bulk operations")
	}
}
