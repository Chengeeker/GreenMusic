import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_system/components/app_section_card.dart';
import '../player/download_queue.dart';
import '../providers.dart';
import 'widgets.dart';

String downloadStatusLabel(DownloadStatus status) => switch (status) {
  DownloadStatus.queued => '等待下载',
  DownloadStatus.running => '正在下载',
  DownloadStatus.saved => '已保存',
  DownloadStatus.skipped => '已有下载，已跳过',
  DownloadStatus.failed => '失败',
  DownloadStatus.cancelled => '已取消',
};

class DownloadQueueCard extends ConsumerWidget {
  const DownloadQueueCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(authProvider);
    final handler = ref.read(playerProvider),
        queue = ref.read(playerProvider).downloadQueue;
    return ListenableBuilder(
      listenable: queue,
      builder: (context, _) {
        if (queue.items.isEmpty || queue.owner != handler.account) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: AppSectionCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${queue.title} · ${queue.busy
                        ? queue.cancelled
                              ? '正在取消'
                              : '下载中'
                        : '任务已结束'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${queue.finished} / ${queue.items.length} 首 · 已保存 ${queue.count(DownloadStatus.saved)} · 跳过 ${queue.count(DownloadStatus.skipped)} · 失败 ${queue.count(DownloadStatus.failed)} · 取消 ${queue.count(DownloadStatus.cancelled)}',
                  ),
                  const SizedBox(height: 8),
                  if (queue.stopReason != null) Text(queue.stopReason!),
                  LinearProgressIndicator(
                    value: queue.finished / queue.items.length,
                    semanticsLabel: '批量下载完成进度',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () =>
                            openPage(context, const DownloadTasksPage()),
                        child: const Text('查看任务'),
                      ),
                      if (queue.busy)
                        TextButton(
                          onPressed: queue.cancelled
                              ? null
                              : () =>
                                    runAction(context, handler.cancelDownload),
                          child: const Text('取消全部'),
                        ),
                      if (!queue.busy &&
                          queue.items.any(
                            (i) => [
                              DownloadStatus.failed,
                              DownloadStatus.cancelled,
                            ].contains(i.status),
                          ))
                        TextButton(
                          onPressed: () =>
                              runAction(context, handler.retryDownloads),
                          child: const Text('重试未完成'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class DownloadTasksPage extends ConsumerWidget {
  const DownloadTasksPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(authProvider);
    final handler = ref.read(playerProvider),
        queue = ref.read(playerProvider).downloadQueue;
    return MusicScaffold(
      title: '下载任务',
      body: ListenableBuilder(
        listenable: queue,
        builder: (context, _) {
          if (queue.owner != handler.account) {
            return const EmptyPanel('请切回原账号查看下载任务');
          }
          return ListView.builder(
            padding: pagePadding(context),
            itemCount: queue.items.length,
            itemBuilder: (context, index) {
              final item = queue.items[index];
              return ListTile(
                title: Text(item.song.name),
                subtitle: Text(
                  [
                    item.song.artistNames,
                    downloadStatusLabel(item.status),
                    if (item.attempt > 0) '第 ${item.attempt} 次重试',
                    if (item.error != null) item.error!,
                  ].where((s) => s.isNotEmpty).join('\n'),
                ),
                leading: Icon(switch (item.status) {
                  DownloadStatus.saved ||
                  DownloadStatus.skipped => Icons.check_circle_outline,
                  DownloadStatus.failed => Icons.error_outline,
                  DownloadStatus.cancelled => Icons.cancel_outlined,
                  _ => Icons.downloading_rounded,
                }),
              );
            },
          );
        },
      ),
    );
  }
}

class ActiveDownloads extends ConsumerWidget {
  const ActiveDownloads({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerProvider),
        cache = ref.read(playerProvider).cache;
    return ValueListenableBuilder(
      valueListenable: cache.transfers,
      builder: (context, transfers, _) {
        final tasks = transfers.values;
        return Column(
          children: [
            for (final task in tasks.where((t) => t.account == handler.account))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: AppSectionCard(
                  child: Column(
                    children: [
                      ListTile(
                        title: Text('${task.stage}：${task.song.name}'),
                        subtitle: Text(
                          '${downloadSize(task.received)}${task.total > 0 ? ' / ${downloadSize(task.total)}' : ''}${task.bytesPerSecond > 0 ? ' · ${downloadSize(task.bytesPerSecond.round())}/s' : ''}',
                        ),
                        trailing: IconButton(
                          tooltip:
                              handler.downloadQueue.busy &&
                                  handler.downloadQueue.items.length > 1
                              ? '取消全部下载'
                              : '取消下载',
                          onPressed: () =>
                              runAction(context, handler.cancelDownload),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                      LinearProgressIndicator(
                        value: task.fraction,
                        semanticsLabel: '${task.song.name}下载进度',
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
