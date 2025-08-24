# libipc - C++ IPC 通信库分析文档

## 概述

libipc 是一个基于共享内存的高性能跨平台（Linux/Windows）进程间通信库，采用C++17编写，无外部依赖，支持多种生产者-消费者模式。

## 共享内存管理

### 共享内存句柄 (shm::handle)

```cpp
class handle {
    shm::id_t id_ = nullptr;  // 共享内存标识符
    void*     m_  = nullptr;   // 内存指针
    ipc::string n_;           // 共享内存名称
    std::size_t s_ = 0;       // 共享内存大小
};
```

### 核心操作

1. **获取共享内存**：
   ```cpp
   bool acquire(char const *name, std::size_t size, unsigned mode);
   ```
   - 创建或打开指定名称和大小的共享内存
   - 返回内存指针和实际大小

2. **释放共享内存**：
   ```cpp
   std::int32_t release();
   ```
   - 减少引用计数，当引用为0时真正释放内存

3. **清理存储**：
   ```cpp
   void clear_storage(char const *name);
   ```
   - 强制清理指定名称的共享内存文件

## 同步机制

### 互斥锁 (ipc::sync::mutex) vs std::mutex

**设计目标差异**：
- `std::mutex`：单进程内线程同步，轻量级
- `ipc::sync::mutex`：跨进程同步，基于共享内存，支持命名和持久化

**实现架构对比**：
```cpp
// std::mutex (简化)
class mutex {
    atomic<int> state;  // 0=未锁定, 1=锁定
};

// ipc::sync::mutex
class mutex {
    robust_mutex *mutex_;           // 底层鲁棒互斥锁
    atomic<int32_t> *ref_;          // 引用计数器
    map<string, shm_data> handles;  // 共享内存存储
};
```

**关键特性**：
| 特性 | std::mutex | ipc::sync::mutex |
|------|------------|---------------------|
| 跨进程支持 | ❌ 不支持 | ✅ 支持 |
| 命名互斥锁 | ❌ 不支持 | ✅ 支持 |
| 鲁棒性处理 | ❌ 有限支持 | ✅ 完整支持 |
| 超时锁定 | ✅ 支持 | ✅ 支持 |
| 引用计数 | ❌ 不支持 | ✅ 支持 |
| 内存管理 | 栈/堆分配 | 共享内存分配 |

**鲁棒性处理机制**：
```cpp
case EOWNERDEAD: {
    a0_mtx_consistent(native());  // 标记为一致状态
    a0_mtx_unlock(native());      // 解锁让其他进程获取
    break; // 循环重试
}
```

### 条件变量 (ipc::sync::condition)  
- 跨进程条件变量，基于POSIX条件变量实现
- 与互斥锁配合使用，支持超时等待
- 支持单播(notify)和广播(broadcast)通知

### 等待器 (ipc::detail::waiter)
```cpp
class waiter {
    ipc::sync::condition cond_;
    ipc::sync::mutex     lock_;
    std::atomic<bool>    quit_ {false};
};
```
- 组合了条件变量和互斥锁的高级抽象
- 提供优雅的等待/通知机制
- 支持优雅退出和超时控制

### 性能与适用场景

**std::mutex优势**：
- 单进程内性能最优
- 无共享内存和命名解析开销
- 适合纯线程同步场景

**libipc同步机制优势**：
- 跨进程通信无需序列化
- 共享内存访问性能高
- 支持进程崩溃恢复
- 适合分布式系统同步

## 消息队列架构

### 队列类型系统

libipc 支持多种生产者-消费者模式：

| 模式 | 描述 | 适用场景 |
|------|------|----------|
| `single-single-unicast` | 单生产者单消费者 | 点对点通信 |
| `single-multi-unicast` | 单生产者多消费者 | 工作队列 |
| `multi-multi-unicast` | 多生产者多消费者 | 竞争消费 |
| `single-multi-broadcast` | 单生产者多消费者广播 | 事件通知 |
| `multi-multi-broadcast` | 多生产者多消费者广播 | 发布订阅 |

### 队列实现核心

#### 1. 队列连接管理 (queue_conn)
```cpp
class queue_conn {
    circ::cc_t connected_ = 0;    // 连接状态
    shm::handle elems_h_;         // 共享内存句柄
};
```

#### 2. 队列基类 (queue_base)
```cpp
template <typename Elems>
class queue_base : public queue_conn {
    elems_t * elems_ = nullptr;           // 元素数组指针
    decltype(elems_t::cursor()) cursor_ = 0; // 当前游标
    bool sender_flag_ = false;            // 发送者标志
};
```

#### 3. 最终队列接口 (queue)
```cpp
template <typename T, typename Policy>
class queue final : public detail::queue_base<...> {
    // 提供类型安全的push/pop接口
};
```

## 消息尺寸处理策略

### 关键设计：每种尺寸独立队列

libipc 采用**每种消息尺寸使用独立队列**的设计，通过模板化机制实现尺寸控制：

#### 1. 队列生成器模板
```cpp
template <typename Policy,
          std::size_t DataSize  = ipc::data_length,
          std::size_t AlignSize = (ipc::detail::min)(DataSize, alignof(std::max_align_t))>
struct queue_generator {
    using queue_t = ipc::queue<msg_t<DataSize, AlignSize>, Policy>;
    // ...
};
```

#### 2. 队列命名包含尺寸标识
```cpp
que_.open(ipc::make_prefix(prefix_, {
          "QU_CONN__", 
          this->name_, 
          "__", ipc::to_string(DataSize),  // 数据尺寸标识
          "__", ipc::to_string(AlignSize)  // 对齐尺寸标识
}).c_str());
```

#### 3. 消息处理策略
libipc根据消息大小采用不同的处理方式：

1. **小消息**（≤ `ipc::data_length` = 64字节）：
   - 直接存储在队列元素中
   - 使用`msg_t`模板存储数据
   - 零拷贝，最高性能

2. **大消息**（> `ipc::large_msg_limit` = 64字节）：
   - 使用共享内存块存储
   - 队列中只存储共享内存块的ID（4-8字节）
   - 通过`acquire_storage()`和`find_storage()`管理
   - 需要额外的共享内存分配和释放开销

3. **分段传输**：
   - 如果消息大于64字节但不超过大消息限制
   - 会被分割成多个64字节片段传输
   - 接收端重新组装
   - 需要组装开销，可能影响性能

#### 4. 元素数组配置
```cpp
template <typename Policy, std::size_t DataSize, std::size_t AlignSize>
class elem_array {
    enum : std::size_t {
        data_size  = DataSize,    // 数据大小
        elem_max   = 256,         // 最大元素数(默认)
        elem_size  = sizeof(elem_t), // 元素总大小
        block_size = elem_size * elem_max // 总块大小
    };
};
```

#### 5. 元素存储结构
```cpp
template <std::size_t DataSize, std::size_t AlignSize>
struct elem_t {
    std::aligned_storage_t<DataSize, AlignSize> data_; // 对齐存储
    // 根据不同策略可能有额外的同步字段
};
```

### ipc::channel创建过程

1. **模板实例化**：根据Policy和尺寸参数实例化特定的queue_generator
2. **共享内存分配**：为队列分配适当大小的共享内存
3. **队列初始化**：创建包含尺寸标识的唯一队列名称
4. **连接管理**：建立发送者/接收者连接

### 尺寸控制的关键常量

在`def.h`中定义了关键的尺寸常量：
- `ipc::data_length` = 64 - 默认消息数据长度
- `ipc::large_msg_limit` = 64 - 大消息阈值
- `ipc::large_msg_align` = 1024 - 大消息对齐要求
- `ipc::large_msg_cache` = 32 - 大消息缓存数量

### ipc::channel发送不同长度消息的处理机制

#### 发送处理流程（send函数）
根据消息大小采用不同的策略：

**小消息（≤64字节）**
```cpp
// 直接存储在队列元素中
return try_push(remain, data, size);
```

**大消息（>64字节）**
```cpp
// 使用共享内存存储
auto dat = acquire_storage(inf, size, conns);
void * buf = dat.second;
if (buf != nullptr) {
    std::memcpy(buf, data, size);
    return try_push(static_cast<std::int32_t>(size) - 
                    static_cast<std::int32_t>(ipc::data_length), 
                    &(dat.first), 0);
}
```

**分段传输（中等消息）**
```cpp
// 分割成多个64字节片段
for (std::int32_t i = 0; i < static_cast<std::int32_t>(size / ipc::data_length); ++i) {
    if (!try_push(remain, data + offset, ipc::data_length)) {
        return false;
    }
}
// 处理剩余部分
if (remain > 0) {
    if (!try_push(remain - ipc::data_length, data + offset, remain)) {
        return false;
    }
}
```

#### 接收处理流程（recv函数）
接收端根据消息类型进行相应处理：

**小消息直接返回**
```cpp
if (msg_size <= ipc::data_length) {
    return make_cache(msg.data_, msg_size);
}
```

**大消息从共享内存获取**
```cpp
if (msg.storage_) {
    ipc::storage_id_t buf_id = *reinterpret_cast<ipc::storage_id_t*>(&msg.data_);
    void* buf = find_storage(buf_id, inf, msg_size);
    return ipc::buff_t{buf, msg_size};
}
```

**分段消息组装**
```cpp
// 使用线程本地存储缓存分段消息
auto& rc = inf->recv_cache();
rc.emplace(msg.id_, cache_t { ipc::data_length, make_cache(msg.data_, msg_size) });
// 后续片段追加到缓存
cac.append(&(msg.data_), ipc::data_length);
```

### 共享内存管理

对于大消息，使用专门的共享内存管理：

```cpp
std::pair<ipc::storage_id_t, void*> acquire_storage(conn_info_head *inf, std::size_t size, ipc::circ::cc_t conns) {
    std::size_t chunk_size = calc_chunk_size(size);
    auto info = chunk_storage_info(inf, chunk_size);
    // 获取存储块并返回ID和指针
}
```

### 优势分析

1. **内存局部性**：相同尺寸的消息连续存储，提高缓存命中率
2. **无内存碎片**：避免不同尺寸消息混合导致的内存碎片
3. **简化管理**：每种队列只需处理单一尺寸的消息
4. **性能优化**：可以针对特定尺寸进行优化
5. **灵活的尺寸控制**：通过模板参数控制队列尺寸
6. **无硬性长度限制**：理论上只受共享内存大小限制
7. **性能优化**：根据消息大小选择最优传输策略

### 限制说明

- 每个队列有固定的最大元素数（默认256个）
- 消息尺寸在队列创建时确定，运行时不可改变
- 大消息需要使用共享内存存储机制
- 大消息和分段消息有额外的性能开销

### 性能优化特性

1. **零拷贝小消息**：≤64字节的消息直接存储，无额外开销
2. **共享内存大消息**：>64字节的消息使用共享内存，队列中只存储ID
3. **分段传输**：避免大消息阻塞队列
4. **连接感知**：支持多生产者多消费者场景
5. **内存回收**：自动管理共享内存生命周期

## 生产者-消费者实现

### 核心策略 (prod_cons_impl)

libipc 为每种模式提供了专门的实现：

#### 1. 单生产者单消费者 (unicast)
- 简单的读/写指针管理
- 无竞争条件下的最高性能

#### 2. 单生产者多消费者 (unicast)  
- 支持多个消费者竞争消费
- 使用原子操作保证线程安全

#### 3. 多生产者多消费者 (unicast)
- 最复杂的同步场景
- 使用提交标志和epoch机制

#### 4. 广播模式 (broadcast)
- 支持消息广播到所有消费者
- 使用读计数器和epoch管理

## 连接管理

### 连接标识系统
```cpp
using cc_t = /* 连接标识类型 */;
```

### 连接状态管理
1. **发送者连接**：
   - `connect_sender()` - 建立发送者连接
   - `disconnect_sender()` - 断开发送者连接

2. **接收者连接**：
   - `connect_receiver()` - 建立接收者连接
   - `disconnect_receiver()` - 断开接收者连接

3. **连接限制**：
   - 最多支持32个接收者（由`circ::cc_t`的位数决定）
   - 发送者数量无限制

## 性能优化特性

### 1. 无锁设计
- 在可能的情况下使用lock-free算法
- 减少线程阻塞和上下文切换

### 2. 缓存优化
- 关键数据结构缓存行对齐
- 避免伪共享(false sharing)

### 3. 忙等待控制
- 重试一定次数后使用信号量等待
- 避免长时间忙等待消耗CPU

### 4. 内存屏障
- 正确使用内存序保证一致性
- `std::memory_order_acquire/release`等

## 使用示例

### 创建队列
```cpp
// 创建单生产者多消费者广播队列
ipc::route queue{"my-queue"};

// 或者使用模板指定具体策略
ipc::queue<MyData, ipc::policy::choose<...>> custom_queue{"custom"};

// 默认队列配置：64字节数据，256元素，约22.5KB共享内存
ipc::channel default_queue{"test"};

// 自定义大容量队列：1KB数据，512元素，约540KB共享内存  
ipc::channel<Policy, 1024, 1024, 512> large_queue{"large-queue"};
```

### 发送消息
```cpp
MyData data{/* ... */};
queue.send(data);  // 阻塞发送
queue.try_send(data); // 非阻塞尝试

// 发送不同大小的消息
char small_msg[32] = "small message"; // ≤64字节，直接存储
char medium_msg[128] = "medium message"; // 64-大消息阈值，分段传输  
char large_msg[1024] = "large message"; // >大消息阈值，共享内存存储

queue.send(small_msg, sizeof(small_msg));
queue.send(medium_msg, sizeof(medium_msg)); 
queue.send(large_msg, sizeof(large_msg));
```

### 接收消息
```cpp
MyData data;
if (queue.recv(data)) {
    // 处理消息
}

// 接收任意大小的消息
ipc::buff_t buff = queue.recv();
if (buff.data() != nullptr) {
    // 处理接收到的数据
    process_data(buff.data(), buff.size());
}
```

### 队列容量配置详解

#### 默认队列配置（ipc::channel c{"test"}）
```cpp
// 等价于：
ipc::channel<
    policy::choose<policy::unicast, policy::broadcast>, // 默认策略
    ipc::data_length,                                   // 64字节数据大小
    (ipc::detail::min)(ipc::data_length, alignof(std::max_align_t)), // 64字节对齐
    256                                                 // 256个元素
> c{"test"};
```

**容量计算**：
- 每个元素大小：头部24字节 + 数据64字节 = 88字节
- 总队列大小：88字节 × 256元素 = 22,528字节（约22KB）
- 共享内存池：32个大消息缓存槽

#### 自定义队列配置
```cpp
// 处理800字节消息的配置
ipc::channel<Policy, 800, 1024, 512> custom_queue{"custom"};

// 容量计算：
// 每个元素：头部24字节 + 数据800字节 = 824字节  
// 总队列大小：824字节 × 512元素 = 421,888字节（约412KB）
```

#### 性能优化建议

1. **小消息场景**（≤64字节）：
   ```cpp
   // 使用默认配置，最高性能
   ipc::channel small_msg_queue{"small"};
   ```

2. **中等消息场景**（64字节-1KB）：
   ```cpp
   // 适当增加元素数避免分段传输阻塞
   ipc::channel<Policy, 256, 256, 512> medium_queue{"medium"};
   ```

3. **大消息场景**（>1KB）：
   ```cpp
   // 使用大消息模式，增加共享内存缓存
   ipc::channel<Policy, 2048, 2048, 256> large_queue{"large"};
   ```

4. **高吞吐场景**：
   ```cpp
   // 增加队列容量和共享内存缓存
   ipc::channel<Policy, 128, 128, 1024> high_throughput_queue{"throughput"};
   ```

### 连接管理示例

```cpp
// 发送者连接
queue.connect_sender();

// 接收者连接  
queue.connect_receiver();

// 检查连接状态
if (queue.connected()) {
    // 有活跃连接
}

// 断开连接
queue.disconnect_sender();
queue.disconnect_receiver();
```

### 错误处理

```cpp
try {
    queue.send(data);
} catch (const ipc::error& e) {
    std::cerr << "IPC error: " << e.what() << std::endl;
}

// 检查发送状态
if (!queue.try_send(data)) {
    // 处理发送失败
}
```

## 总结

libipc 是一个设计精良的IPC通信库，其核心特点包括：

1. **共享内存管理**：完善的引用计数和清理机制
2. **同步机制**：跨进程的互斥锁和条件变量
3. **队列设计**：模板化的多种生产者-消费者模式
4. **尺寸策略**：每种消息尺寸使用独立队列，优化性能和内存使用
5. **性能优化**：无锁算法、缓存优化和合理的忙等待策略

这种设计使得libipc能够高效处理各种IPC场景，同时保持代码的简洁性和可维护性。
