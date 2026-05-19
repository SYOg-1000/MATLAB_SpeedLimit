# 限速标志识别系统 - 对话优化记录

> 本文档记录本次对话中对 `mian.m` 和 `process_flow_diagram.html` 的所有修改。

---

## 一、原始需求

原始 `mian.m` 文件存在缺陷：字符分割模块会提取"限速"、"km/h"等非数字内容，无法只输出纯净的数字（如 60、120）。

---

## 二、用户提出的初始方案

### 方案 A：水平中线交集判定
在分割后的图片画水平中线，只保留与中线相交的连通域。
- **理由**：数字在标志中央，文字在边缘

### 方案 B：置信度过滤
舍弃置信度过低的识别，只保留高置信度结果。
- **理由**：非数字字符的 corr2 匹配分数通常较低

---

## 三、最终实施方案

采用**两遍扫描**方案（最大面积锚定聚类 + 宽度一致性过滤），配合置信度兜底。

### 核心洞察
1. 中文偏旁（阝、艮、辶、束）被二值化拆分成独立连通域，形态特征与数字高度重叠
2. 数字的 bbox 面积永远是标志中最大的
3. 数字沿水平方向排列，Y 坐标一致

---

## 四、代码变更

### 4.1 segment_chars 函数（mian.m 第 291-357 行）

#### 删除的逻辑

```matlab
% 删除：ratio/fill_ratio 组合过滤（无效）
if ratio < 1.20 && fill_ratio > 0.55
    continue;
end
if ratio >= 1.20 && fill_ratio > 0.45
    continue;
end

% 删除：PixelIdxList 属性获取
stats = regionprops(bw_clean, 'BoundingBox', 'Area', 'Centroid', 'PixelIdxList');
```

#### 新增的逻辑

```matlab
% 第一遍：宽松初筛（3个基本条件）
if stats(i).Area <= max_a * 0.15 || ratio < 0.60  % ratio下限从0.85降至0.60
    continue;
end
if abs(cent_y - mid_y) > img_h * 0.40
    continue;
end

% 第二遍：后处理聚类（仅当候选数 > 2）
bbox_areas = cand_bboxes(:, 3) .* cand_bboxes(:, 4);
[~, anchor_idx] = max(bbox_areas);
anchor_y = cand_cent_y(anchor_idx);  % 最大面积锚定（替代median锚定）

if abs(cand_cent_y(i) - anchor_y) > img_h * 0.15  % 从0.12放宽至0.15
    keep(i) = false;
end
if cand_bboxes(i, 3) < avg_w * 0.45
    keep(i) = false;
end
```

### 4.2 recognize_digits 函数（mian.m 第 347-378 行）

#### 新增的逻辑

```matlab
if max_corr < 0.15
    best_digit = '?';
end

if contains(speed_val, '?')
    confidence = 0;
end
```

### 4.3 process_flow_diagram.html

完全重写，步骤与代码逻辑一一对应：

| 步骤 | 名称 | 对应函数/操作 |
|------|------|--------------|
| 1 | 原始图像 | ensure_rgb() |
| 2 | CLAHE增强 | adapthisteq() |
| 3 | HSV红色分割 | color_segment_red() |
| 4 | 形态学处理 | imclose + imfill |
| 5 | 连通域筛选 | regionprops + 形态学准则 |
| 6 | IoU-NMS | nms_boxes() |
| 7 | ROI截取 | 数组切片裁剪 |
| 8 | 透视校正 | perspective_correction() |
| 9 | 内部裁剪 | extract_inner_region() |
| 10 | 二值化取反 | imbinarize + ~ |
| 11 | 去噪 | imclearborder + bwareaopen |
| 12 | 候选提取 | regionprops 初筛 |
| 13 | 聚类过滤 | Y锚定 + 宽度聚类 |
| 14 | X轴排序 | sort(bbox, 1) |
| 15 | 归一化 | imresize(32,16) |
| 16 | 模板匹配 | recognize_digits() |
| 17 | 最终结果 | process_single_image() |

---

## 五、解决的问题

### 问题 1："0"被误过滤
- **现象**：带"0"的图像（如"60"）被识别为"6"
- **根因**：高宽比下限 `ratio < 0.85` 误杀了接近正方形的"0"
- **修复**：将下限降至 `0.60`

### 问题 2：中文偏旁被误提取
- **现象**："限速60km/h"图像识别出"6艮0束"
- **根因**：ratio/fill_ratio 组合条件无法区分中文偏旁和数字
- **修复**：删除该条件，改用 Y一致性 + 宽度聚类

### 问题 3：偏旁多时 median 锚定失效
- **现象**："限速60km/h"图像返回空
- **根因**：4个偏旁绑架了中位数，导致数字被 Y 过滤剔除，宽度过滤又杀死了剩余偏旁
- **修复**：改用最大面积候选的 Y 坐标作为锚点

### 问题 4：矮宽"4"被误过滤
- **现象**：两个"40"标志中，矮宽的"4"检测失败
- **根因**：高宽比下限过高
- **修复**：将下限从 `0.85` 降至 `0.60`

### 问题 5：流程图与代码不对应
- **现象**：HTML 流程图的步骤和可视化与实际代码逻辑不符
- **修复**：完全重写，17 个步骤与代码一一对应

---

## 六、调参过程

| 轮次 | 修改内容 | 结果 |
|------|---------|------|
| 第1轮 | 初始 ratio=1.1 过滤 | "0"被误杀 |
| 第2轮 | ratio=1.3 组合过滤 | 部分数字被误杀 |
| 第3轮 | ratio 放宽至 0.85，fill 放宽至 0.75 | 中文偏旁仍通过 |
| 第4轮 | 添加 ratio/fill 组合条件 | 偏旁特征与数字重叠，无效 |
| 第5轮 | 两遍扫描，median 锚定 | 偏旁多时锚点被绑架 |
| 第6轮 | 改用 max-bbox-area 锚定 | 成功解决所有问题 |

---

## 七、关键参数索引

| 参数 | 位置 | 当前值 | 说明 |
|------|------|--------|------|
| 高宽比下限 | segment_chars L312 | 0.60 | 允许矮宽字符通过 |
| 中线容差 | segment_chars L317 | 0.40 | 图像中线附近的范围 |
| Y锚定阈值 | segment_chars L336 | 0.15 | 与最大面积候选的偏差容忍度 |
| 最小宽度比 | segment_chars L338 | 0.45 | width / avg_width 的最小值 |
| 置信度阈值 | recognize_digits L365 | 0.15 | 低于此值标记为"?" |

---

## 八、文件清单

| 文件路径 | 说明 |
|----------|------|
| `mian.m` | 主程序，含 segment_chars 和 recognize_digits 修改 |
| `structure/process_flow_diagram.html` | 重写的流程图，与代码对应 |
| `功能变更记录.md` | 本次对话的详细变更记录 |
| `.trae/documents/chinese_radical_filter_plan.md` | 中文偏旁过滤方案计划书 |
| `.trae/documents/cluster_anchor_fix_plan.md` | 聚类锚定修复方案计划书 |

---

*生成日期：2026-05-19*
