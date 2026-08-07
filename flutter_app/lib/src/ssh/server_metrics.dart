import '../domain/models.dart';

const serverMetricsScript = r'''
set -u

sample_cpu() {
  awk '/^cpu / {
    total=$2+$3+$4+$5+$6+$7+$8+$9
    idle=$5+$6
    printf "%.0f %.0f\n", total, idle
    exit
  }' /proc/stat 2>/dev/null
}

network_interface=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route 2>/dev/null)
sample_network() {
  awk -v iface="$network_interface" '
    NR <= 2 { next }
    {
      split($0, parts, ":")
      if (length(parts) < 2) next
      name=parts[1]
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      data=parts[2]
      gsub(/^[ \t]+/, "", data)
      count=split(data, counters, /[ \t]+/)
      if (count < 9) next
      if (iface != "") {
        if (name == iface) {
          print counters[1], counters[9]
          found=1
          exit
        }
      } else if (name != "lo") {
        downloaded+=counters[1]
        uploaded+=counters[9]
        found=1
      }
    }
    END {
      if (iface == "" && found) print downloaded, uploaded
      else if (!found) print "-1 -1"
    }
  ' /proc/net/dev 2>/dev/null
}

read total_a idle_a <<EOF
$(sample_cpu)
EOF
read downloaded_a uploaded_a <<EOF
$(sample_network)
EOF
sleep 1
read total_b idle_b <<EOF
$(sample_cpu)
EOF
read downloaded_b uploaded_b <<EOF
$(sample_network)
EOF

cpu=-1
if [ "${total_b:-0}" -gt "${total_a:-0}" ]; then
  total_delta=$((total_b - total_a))
  idle_delta=$((idle_b - idle_a))
  cpu=$(( (total_delta - idle_delta) * 100 / total_delta ))
fi

download_speed=-1
upload_speed=-1
if [ "${downloaded_a:-1}" -ge 0 ] && [ "${downloaded_b:-1}" -ge "${downloaded_a:-1}" ] && \
  [ "${uploaded_a:-1}" -ge 0 ] && [ "${uploaded_b:-1}" -ge "${uploaded_a:-1}" ]; then
  download_speed=$((downloaded_b - downloaded_a))
  upload_speed=$((uploaded_b - uploaded_a))
fi

cpu_cores=$(awk '/^processor[[:space:]]*:/ { count++ } END { if (count > 0) print count; else print "--" }' /proc/cpuinfo 2>/dev/null)

memory=$(awk '
/^MemTotal:/ { total=$2 }
/^MemAvailable:/ { available=$2 }
/^MemFree:/ { free=$2 }
/^Buffers:/ { buffers=$2 }
/^Cached:/ { cached=$2 }
END {
  if (available == 0) available=free+buffers+cached
  if (total > 0) {
    used=total-available
    if (used < 0) used=0
    printf "%.0f|%.0f|%.0f", (used*100)/total, total, used
  } else print "-1|--|--"
}' /proc/meminfo 2>/dev/null)

disk=$(df -P -k / 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); printf "%s|%s|%s", $5, $2, $3; exit }')
memory_percent=${memory%%|*}
memory_sizes=${memory#*|}
memory_total=${memory_sizes%%|*}
memory_used=${memory_sizes#*|}
disk_percent=${disk%%|*}
disk_sizes=${disk#*|}
disk_total=${disk_sizes%%|*}
disk_used=${disk_sizes#*|}
printf "CODEX_METRICS|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
  "$cpu" "${memory_percent:---}" "${disk_percent:---}" \
  "${memory_total:---}" "${memory_used:---}" "${cpu_cores:---}" \
  "${disk_total:---}" "${disk_used:---}" "$download_speed" "$upload_speed"
''';

ServerMetrics parseServerMetrics(String output, {int? sampledAtEpochMillis}) {
  final sampledAt =
      sampledAtEpochMillis ?? DateTime.now().millisecondsSinceEpoch;
  String? markerLine;
  final lines = output.split(RegExp(r'\r?\n'));
  for (var index = lines.length - 1; index >= 0; index--) {
    final line = lines[index].trim();
    if (line.startsWith('CODEX_METRICS|')) {
      markerLine = line;
      break;
    }
  }
  final fields = markerLine?.split('|');
  if (fields == null || fields.length < 4) {
    return ServerMetrics(sampledAtEpochMillis: sampledAt, error: '远端未返回资源数据');
  }

  int? parsePercent(String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < 0) return null;
    return parsed.clamp(0, 100).toInt();
  }

  int? parsePositive(String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  int? parseNonNegative(String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  String? field(int index) => index < fields.length ? fields[index] : null;

  final memoryTotalKiB = parseNonNegative(field(4));
  final parsedMemoryUsedKiB = parseNonNegative(field(5));
  final memoryUsedKiB =
      parsedMemoryUsedKiB != null &&
          (memoryTotalKiB == null || parsedMemoryUsedKiB <= memoryTotalKiB)
      ? parsedMemoryUsedKiB
      : null;
  final diskTotalKiB = parseNonNegative(field(7));
  final parsedDiskUsedKiB = parseNonNegative(field(8));
  final diskUsedKiB =
      parsedDiskUsedKiB != null &&
          (diskTotalKiB == null || parsedDiskUsedKiB <= diskTotalKiB)
      ? parsedDiskUsedKiB
      : null;

  return ServerMetrics(
    cpuPercent: parsePercent(field(1)),
    memoryPercent: parsePercent(field(2)),
    diskPercent: parsePercent(field(3)),
    memoryTotalKiB: memoryTotalKiB,
    memoryUsedKiB: memoryUsedKiB,
    cpuCoreCount: parsePositive(field(6)),
    diskTotalKiB: diskTotalKiB,
    diskUsedKiB: diskUsedKiB,
    networkDownloadBytesPerSecond: parseNonNegative(field(9)),
    networkUploadBytesPerSecond: parseNonNegative(field(10)),
    sampledAtEpochMillis: sampledAt,
  );
}
