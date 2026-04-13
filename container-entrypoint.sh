#!/bin/bash
set -e

echo "🚀 PENTAGI KALI CONTAINER INITIALIZATION"
echo "========================================"

### 1. 【关键】文件系统初始化和等待 ###
echo "🔧 STEP 1: Initializing filesystem and waiting for mounts..."

# 创建必要的目录结构
mkdir -p /run/systemd /var/log /root/.config/xray /work /root/.sqlmap
chmod 755 /run /var/log /work
chmod 700 /root/.config/xray /root/.sqlmap

# 智能等待文件系统完全挂载（关键！）
wait_for_mounts() {
    local max_attempts=20
    local attempt=0
    
    echo "⏳ Waiting for filesystem mounts to complete..."
    
    while [ $attempt -lt $max_attempts ]; do
        # 检查关键挂载点
        local mounts_ready=true
        
        # 检查 xray 目录是否存在且可访问
        if [ ! -d "/root/xray" ] || [ ! -x "/root/xray/xray" ]; then
            mounts_ready=false
            echo "   ⚠️  /root/xray not ready yet..."
        fi
        
        # 检查工作目录
        if [ ! -d "/work" ] || [ ! -w "/work" ]; then
            mounts_ready=false
            echo "   ⚠️  /work directory not ready yet..."
        fi
        
        # 检查 systemd 目录
        if [ ! -d "/run/systemd" ]; then
            mounts_ready=false
            echo "   ⚠️  /run/systemd not ready yet..."
        fi
        
        # 检查 sqlmap 配置目录
        if [ ! -d "/root/.sqlmap" ] || [ ! -w "/root/.sqlmap" ]; then
            mounts_ready=false
            echo "   ⚠️  /root/.sqlmap directory not ready yet..."
        fi
        
        if [ "$mounts_ready" = true ]; then
            echo "✅ All filesystem mounts are ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 0.3
    done
    
    echo "⚠️  Filesystem mounts not fully ready after $max_attempts attempts, continuing anyway..."
    return 1
}

# 执行等待
wait_for_mounts

### 2. 【关键】权限修复 ###
echo "🔧 STEP 2: Fixing all critical permissions..."

# xray 相关权限
if [ -f "/root/xray/xray" ]; then
    echo "   ✅ Fixing xray binary permissions..."
    chmod +x /root/xray/xray
    chown root:root /root/xray/xray
fi

# 修复配置目录权限
if [ -d "/root/xray" ]; then
    echo "   ✅ Fixing xray directory permissions..."
    chown -R root:root /root/xray
    chmod -R 755 /root/xray
    find /root/xray -type f -name "*.yaml" -exec chmod 644 {} \;
fi

# 修复证书目录权限
echo "   ✅ Fixing config directory permissions..."
chown -R root:root /root/.config/xray
chmod -R 700 /root/.config/xray

# 修复工作目录权限
echo "   ✅ Fixing work directory permissions..."
chown -R root:root /work
chmod -R 755 /work

# 【新增】sqlmap 相关权限修复
echo "   ✅ Fixing sqlmap permissions and directories..."

# 确保 sqlmap 二进制文件有执行权限
if command -v sqlmap >/dev/null 2>&1; then
    SQLMAP_BIN=$(which sqlmap)
    chmod +x "$SQLMAP_BIN"
    echo "      → sqlmap binary: $SQLMAP_BIN"
else
    echo "      ⚠️  sqlmap binary not found in PATH"
fi

# 修复 sqlmap 配置目录权限
if [ -d "/root/.sqlmap" ]; then
    chown -R root:root /root/.sqlmap
    chmod -R 700 /root/.sqlmap
    echo "      → sqlmap config directory permissions fixed"
else
    mkdir -p /root/.sqlmap
    chown -R root:root /root/.sqlmap
    chmod -R 700 /root/.sqlmap
    echo "      → sqlmap config directory created"
fi

# 修复 sqlmap 缓存目录（如果存在）
if [ -d "/tmp/sqlmap" ]; then
    chown -R root:root /tmp/sqlmap
    chmod -R 755 /tmp/sqlmap
    echo "      → sqlmap cache directory permissions fixed"
fi

### 3. 【关键】xray 证书生成 ###
echo "🔧 STEP 3: Generating xray certificates (if needed)..."

CERT_DIR="/root/.config/xray"
if [ ! -f "$CERT_DIR/ca.crt" ] || [ ! -f "$CERT_DIR/ca.key" ]; then
    if [ -x "/root/xray/xray" ]; then
        echo "   🔒 Generating xray CA certificates..."
        /root/xray/xray genca -d "$CERT_DIR/" 2>/dev/null || {
            echo "   ⚠️  Certificate generation failed, but continuing..."
        }
        
        if [ -f "$CERT_DIR/ca.crt" ] && [ -f "$CERT_DIR/ca.key" ]; then
            echo "   ✅ Certificates generated successfully!"
        else
            echo "   ⚠️  Certificates not found after generation attempt"
        fi
    else
        echo "   ⚠️  xray binary not available for certificate generation"
    fi
else
    echo "   ✅ Certificates already exist, skipping generation"
fi

### 4. 【新增】sqlmap 配置初始化 ###
echo "🔧 STEP 4: Initializing sqlmap configuration..."

SQLMAP_CONFIG_DIR="/root/.sqlmap"
SQLMAP_CONFIG_FILE="$SQLMAP_CONFIG_DIR/sqlmap.conf"

# 创建 sqlmap 配置文件（如果不存在）
if [ ! -f "$SQLMAP_CONFIG_FILE" ]; then
    echo "   📝 Creating default sqlmap configuration..."
    mkdir -p "$SQLMAP_CONFIG_DIR"
    
    cat > "$SQLMAP_CONFIG_FILE" << EOF
[sqlmap]
# Default configuration for sqlmap in container
batch = True
flush-session = True
threads = 4
timeout = 30
retries = 3
level = 1
risk = 1
optimize = True
output-dir = /work/sqlmap_results
tmp-dir = /tmp/sqlmap
ignore-proxy = True
# Enable verbose output for debugging
verbose = 1
EOF
    
    chown root:root "$SQLMAP_CONFIG_FILE"
    chmod 644 "$SQLMAP_CONFIG_FILE"
    echo "   ✅ sqlmap configuration created at $SQLMAP_CONFIG_FILE"
else
    echo "   ✅ sqlmap configuration already exists: $SQLMAP_CONFIG_FILE"
fi

# 确保输出目录存在
OUTPUT_DIR="/work/sqlmap_results"
mkdir -p "$OUTPUT_DIR"
chown -R root:root "$OUTPUT_DIR"
chmod -R 755 "$OUTPUT_DIR"
echo "   ✅ sqlmap output directory created: $OUTPUT_DIR"

### 5. 环境变量配置 ###
echo "🔧 STEP 5: Setting up environment variables..."

# 设置 PATH（确保所有工具可访问）
export PATH="/usr/local/bin:/usr/bin:/bin:/root/xray:/root/go/bin:/opt/venv/bin:$PATH"
export XRAX_HOME="/root/xray"
export XRAX_CONFIG_DIR="/root/.config/xray"
export SQLMAP_HOME="/root/.sqlmap"
export SQLMAP_OUTPUT_DIR="/work/sqlmap_results"
export SYSTEMCTL_DEBUG="false"

# 设置 sqlmap 环境变量
export SQLMAP_CONF_PATH="$SQLMAP_CONFIG_FILE"
export SQLMAP_TMPDIR="/tmp/sqlmap"
mkdir -p "$SQLMAP_TMPDIR"
chmod 777 "$SQLMAP_TMPDIR"

# 验证 PATH 设置
echo "   ✅ PATH configured: $(echo $PATH | tr ':' '\n' | head -3 | tr '\n' ':')..."

### 6. 工具验证 ###
echo "🔧 STEP 6: Verifying critical tools..."

verify_tool() {
    local tool=$1
    local command=$2
    
    if command -v "$tool" >/dev/null 2>&1; then
        local version=$($command 2>/dev/null | head -1 || echo "unknown")
        echo "   ✅ $tool: $version"
        return 0
    else
        echo "   ⚠️  $tool: not available"
        return 1
    fi
}

echo "   🔍 Checking essential tools:"
verify_tool "xray" "/usr/local/bin/xray version" || true
verify_tool "nmap" "nmap --version" || true
verify_tool "sqlmap" "sqlmap --version" || true
verify_tool "python3" "python3 --version" || true
verify_tool "bash" "bash --version" || true

# 【新增】sqlmap 详细验证
if command -v sqlmap >/dev/null 2>&1; then
    echo "   🔍 Detailed sqlmap verification:"
    echo "      → sqlmap location: $(which sqlmap)"
    echo "      → sqlmap config: $SQLMAP_CONFIG_FILE"
    echo "      → sqlmap output dir: $OUTPUT_DIR"
    
    # 测试 sqlmap 基本功能
    if sqlmap --version >/dev/null 2>&1; then
        echo "      ✅ sqlmap basic functionality verified"
    else
        echo "      ⚠️  sqlmap basic functionality test failed"
    fi
    
    # 检查 sqlmap 依赖
    echo "      → Checking sqlmap dependencies:"
    if python3 -c "import sqlalchemy" >/dev/null 2>&1; then
        echo "         ✅ sqlalchemy: available"
    else
        echo "         ⚠️  sqlalchemy: not available (sqlmap may have limited functionality)"
    fi
    
    if python3 -c "import requests" >/dev/null 2>&1; then
        echo "         ✅ requests: available"
    else
        echo "         ⚠️  requests: not available (sqlmap may have limited functionality)"
    fi
fi

### 7. 清理函数（增强版） ###
cleanup() {
    echo ""
    echo "🛑 Container shutting down gracefully..."
    
    # 清理临时文件
    if [ -d "/tmp" ]; then
        echo "   🧹 Cleaning up temporary files..."
        find /tmp -type f -name "*.tmp" -delete 2>/dev/null || true
        find /tmp -type f -name "*.sqlmap" -delete 2>/dev/null || true
    fi
    
    # 【新增】清理 sqlmap 临时文件
    if [ -d "/tmp/sqlmap" ]; then
        echo "   🧹 Cleaning up sqlmap temporary files..."
        rm -rf /tmp/sqlmap/* 2>/dev/null || true
    fi
    
    # 停止后台进程（如果有）
    echo "   🚫 Stopping any background processes..."
    pkill -f xray 2>/dev/null || true
    pkill -f nmap 2>/dev/null || true
    pkill -f sqlmap 2>/dev/null || true
    pkill -f python3 2>/dev/null || true
    
    echo "✅ Container shutdown complete"
}

# 设置信号处理
trap cleanup EXIT SIGTERM SIGINT

### 8. 【关键】执行用户命令 ###
echo "✅ INITIALIZATION COMPLETE!"
echo "========================================"
echo ""

# 如果没有参数，启动 bash
if [ $# -eq 0 ]; then
    echo "🎯 Starting interactive shell (/bin/bash)..."
    echo ""
    echo "💡 Available tools:"
    echo "   - xray: /usr/local/bin/xray (or just 'xray')"
    echo "   - nmap: /usr/bin/nmap (or just 'nmap')"
    echo "   - sqlmap: /usr/bin/sqlmap (or just 'sqlmap')"
    echo "   - Output directory for sqlmap: $OUTPUT_DIR"
    echo ""
    exec /bin/bash
else
    # 显示要执行的命令
    echo "🎯 Executing command: $@"
    
    # 特殊处理 sqlmap 命令
    if [ "$1" = "sqlmap" ]; then
        echo "   🐍 Special handling for sqlmap command..."
        
        # 确保输出目录存在
        mkdir -p "$OUTPUT_DIR"
        
        # 如果命令中没有指定输出目录，添加默认输出目录
        if ! echo "$@" | grep -q "\-\-output-dir"; then
            set -- "$@" "--output-dir=$OUTPUT_DIR"
            echo "      → Auto-added output directory: $OUTPUT_DIR"
        fi
        
        # 如果命令中没有指定批量模式，添加批量模式
        if ! echo "$@" | grep -q "\-\-batch"; then
            set -- "$@" "--batch"
            echo "      → Auto-added batch mode (--batch)"
        fi
    fi
    
    # 检查命令是否存在
    if command -v "$1" >/dev/null 2>&1; then
        echo "   ✅ Command '$1' found in PATH"
    else
        echo "   ⚠️  Command '$1' not found in PATH, trying full path..."
    fi
    
    # 执行命令
    exec "$@" || {
        echo "❌ Command execution failed with exit code $?"
        
        # 特殊错误处理：sqlmap 权限问题
        if [ "$1" = "sqlmap" ] && [ $? -eq 13 ]; then
            echo "   🔧 Attempting to fix sqlmap permissions and retry..."
            chmod +x $(which sqlmap) 2>/dev/null || true
            chown -R root:root /root/.sqlmap 2>/dev/null || true
            chmod -R 700 /root/.sqlmap 2>/dev/null || true
            
            echo "   🔄 Retrying command..."
            exec "$@" || {
                echo "❌ Second attempt failed with exit code $?"
                exit 1
            }
        fi
        
        exit 1
    }
fi
