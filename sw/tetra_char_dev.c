/*
 * tetra_char_dev.c — TETRA FPGA Character Device Driver
 *
 * Linux kernel module providing userspace access to TETRA PHY/LMAC
 * hardware registers via /dev/tetra interface.
 *
 * Based on OpenWiFi openwifi_chardev.c (BSD/GPL)
 *
 * License: GPL v2
 *
 * Usage:
 * insmod tetra_char_dev.ko
 * cat /dev/tetra # Read all registers
 * echo "0x0000 0x12345678" > /dev/tetra # Write register
 *
 * IOCTL interface:
 * TETRA_IOCTL_GET_STATUS - Read STATUS register
 * TETRA_IOCTL_SET_CTRL - Write CTRL register
 * TETRA_IOCTL_GET_VERSION - Read VERSION register
 * TETRA_IOCTL_START_RX - Enable RX chain
 * TETRA_IOCTL_STOP_RX - Disable RX chain
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/cdev.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/of.h>
#include <linux/of_address.h>

/* ========================================================================
 * Constants
 * ======================================================================== */

#define DRIVER_NAME "tetra_char_dev"
#define DEVICE_NAME "tetra"
#define CLASS_NAME "tetra_class"

#define TETRA_NR_DEVS 1

/* Register Map (from docs/register_map.md) */
#define TETRA_REG_VERSION 0x0000 /* R: Hardware version */
#define TETRA_REG_STATUS 0x0004 /* R: Status flags */
#define TETRA_REG_CTRL 0x0008 /* R/W: Control register */
#define TETRA_REG_RX_FREQ 0x000C /* R/W: RX frequency (Hz) */
#define TETRA_REG_TX_FREQ 0x0010 /* R/W: TX frequency (Hz) */
#define TETRA_REG_GAIN 0x0014 /* R/W: RX gain (0-73 dB) */
#define TETRA_REG_SYNC 0x0018 /* R: Sync detection status */

/* STATUS register bits */
#define TETRA_STATUS_SYNC_LOCKED (1 << 0) /* Sync sequence detected */
#define TETRA_STATUS_RX_ACTIVE (1 << 1) /* RX chain enabled */
#define TETRA_STATUS_TX_ACTIVE (1 << 2) /* TX chain enabled */
#define TETRA_STATUS_FRAME-valid (1 << 3) /* Valid frame received */

/* CTRL register bits */
#define TETRA_CTRL_RX_ENABLE (1 << 0) /* Enable RX chain */
#define TETRA_CTRL_TX_ENABLE (1 << 1) /* Enable TX chain */
#define TETRA_CTRL_RESET (1 << 31) /* Global reset (active-high) */

/* IOCTL commands */
#define TETRA_IOC_MAGIC 'T'
#define TETRA_IOCTL_GET_STATUS _IOR(TETRA_IOC_MAGIC, 0x01, uint32_t)
#define TETRA_IOCTL_SET_CTRL _IOW(TETRA_IOC_MAGIC, 0x02, uint32_t)
#define TETRA_IOCTL_GET_VERSION _IOR(TETRA_IOC_MAGIC, 0x03, uint32_t)
#define TETRA_IOCTL_START_RX _IO(TETRA_IOC_MAGIC, 0x04)
#define TETRA_IOCTL_STOP_RX _IO(TETRA_IOC_MAGIC, 0x05)

/* ========================================================================
 * Data Structures
 * ======================================================================== */

/**
 * struct tetra_device - Per-device private data
 * @base_addr: MMIO base address (AXI-Lite)
 * @mem_size: Size of register space
 * @cdev: Character device structure
 * @dev: Device pointer
 * @lock: Mutex for exclusive access
 */
struct tetra_device {
 void __iomem *base_addr;
 resource_size_t mem_size;
 struct cdev cdev;
 struct device *dev;
 struct mutex lock;
};

/* ========================================================================
 * Global Variables
 * ======================================================================== */

static dev_t tetra_devno;
static struct class *tetra_class;
static struct tetra_device *tetra_devices[TETRA_NR_DEVS];

/* ========================================================================
 * Register Access Functions
 * ======================================================================== */

/**
 * tetra_read_reg - Read 32-bit register
 * @tdev: Device pointer
 * @offset: Register offset (bytes)
 *
 * Return: Register value
 */
static inline uint32_t tetra_read_reg(struct tetra_device *tdev, uint32_t offset)
{
 return ioread32(tdev->base_addr + offset);
}

/**
 * tetra_write_reg - Write 32-bit register
 * @tdev: Device pointer
 * @offset: Register offset (bytes)
 * @value: Value to write
 */
static inline void tetra_write_reg(struct tetra_device *tdev, uint32_t offset, uint32_t value)
{
 iowrite32(value, tdev->base_addr + offset);
}

/* ========================================================================
 * File Operations
 * ======================================================================== */

/**
 * tetra_open - Open device
 */
static int tetra_open(struct inode *inode, struct file *filp)
{
 struct tetra_device *tdev;
 unsigned int minor = iminor(inode);

 if (minor >= TETRA_NR_DEVS) {
 pr_err("%s: Invalid minor %u\n", DRIVER_NAME, minor);
 return -ENODEV;
 }

 tdev = tetra_devices[minor];
 if (!tdev) {
 pr_err("%s: Device not found for minor %u\n", DRIVER_NAME, minor);
 return -ENODEV;
 }

 filp->private_data = tdev;

 pr_debug("%s: Device opened\n", DRIVER_NAME);
 return 0;
}

/**
 * tetra_release - Close device
 */
static int tetra_release(struct inode *inode, struct file *filp)
{
 pr_debug("%s: Device closed\n", DRIVER_NAME);
 return 0;
}

/**
 * tetra_read - Read registers
 *
 * Reads all registers and returns to userspace as hex dump:
 * "0000: 0x12345678\n"
 * "0004: 0x87654321\n"
 *...
 */
static ssize_t tetra_read(struct file *filp, char __user *buf,
 size_t count, loff_t *f_pos)
{
 struct tetra_device *tdev = filp->private_data;
 char *kbuf;
 ssize_t bytes_read = 0;
 int reg, ret;

 /* Allocate kernel buffer */
 kbuf = kmalloc(PAGE_SIZE, GFP_KERNEL);
 if (!kbuf)
 return -ENOMEM;

 mutex_lock(&tdev->lock);

 /* Dump all registers */
 for (reg = 0; reg < 8; reg++) {
 uint32_t offset = reg * 4;
 uint32_t value = tetra_read_reg(tdev, offset);
 int len;

 len = snprintf(kbuf + bytes_read, PAGE_SIZE - bytes_read,
 "%04x: 0x%08x\n", offset, value);

 if (len < 0 || bytes_read + len >= PAGE_SIZE)
 break;

 bytes_read += len;
 }

 mutex_unlock(&tdev->lock);

 /* Copy to userspace */
 if (*f_pos >= bytes_read) {
 kfree(kbuf);
 return 0;
 }

 if (count > bytes_read - *f_pos)
 count = bytes_read - *f_pos;

 ret = copy_to_user(buf, kbuf + *f_pos, count);
 if (ret) {
 kfree(kbuf);
 return -EFAULT;
 }

 *f_pos += count;
 kfree(kbuf);

 return count;
}

/**
 * tetra_write - Write register
 *
 * Input format: "OFFSET VALUE\n"
 * Example: "0x0008 0x00000001\n"
 */
static ssize_t tetra_write(struct file *filp, const char __user *buf,
 size_t count, loff_t *f_pos)
{
 struct tetra_device *tdev = filp->private_data;
 char kbuf[64];
 uint32_t offset, value;
 int ret;

 if (count >= sizeof(kbuf))
 return -EINVAL;

 if (copy_from_user(kbuf, buf, count))
 return -EFAULT;

 kbuf[count] = '\0';

 /* Parse "OFFSET VALUE" */
 ret = sscanf(kbuf, "%x %x", &offset, &value);
 if (ret != 2) {
 pr_err("%s: Invalid input format. Expected: OFFSET VALUE\n", DRIVER_NAME);
 return -EINVAL;
 }

 /* Validate offset (must be 4-byte aligned) */
 if (offset > TETRA_REG_SYNC || offset % 4 != 0) {
 pr_err("%s: Invalid offset 0x%04x\n", DRIVER_NAME, offset);
 return -EINVAL;
 }

 mutex_lock(&tdev->lock);
 tetra_write_reg(tdev, offset, value);
 mutex_unlock(&tdev->lock);

 pr_debug("%s: Wrote 0x%08x to offset 0x%04x\n", DRIVER_NAME, value, offset);

 *f_pos += count;
 return count;
}

/**
 * tetra_ioctl - IOCTL interface
 */
static long tetra_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
 struct tetra_device *tdev = filp->private_data;
 uint32_t value;
 int ret = 0;

 mutex_lock(&tdev->lock);

 switch (cmd) {
 case TETRA_IOCTL_GET_STATUS:
 value = tetra_read_reg(tdev, TETRA_REG_STATUS);
 if (copy_to_user((uint32_t __user *)arg, &value, sizeof(value)))
 ret = -EFAULT;
 break;

 case TETRA_IOCTL_SET_CTRL:
 if (copy_from_user(&value, (uint32_t __user *)arg, sizeof(value))) {
 ret = -EFAULT;
 } else {
 tetra_write_reg(tdev, TETRA_REG_CTRL, value);
 }
 break;

 case TETRA_IOCTL_GET_VERSION:
 value = tetra_read_reg(tdev, TETRA_REG_VERSION);
 if (copy_to_user((uint32_t __user *)arg, &value, sizeof(value)))
 ret = -EFAULT;
 break;

 case TETRA_IOCTL_START_RX:
 value = tetra_read_reg(tdev, TETRA_REG_CTRL);
 value |= TETRA_CTRL_RX_ENABLE;
 tetra_write_reg(tdev, TETRA_REG_CTRL, value);
 break;

 case TETRA_IOCTL_STOP_RX:
 value = tetra_read_reg(tdev, TETRA_REG_CTRL);
 value &= ~TETRA_CTRL_RX_ENABLE;
 tetra_write_reg(tdev, TETRA_REG_CTRL, value);
 break;

 default:
 pr_err("%s: Unknown IOCTL 0x%08x\n", DRIVER_NAME, cmd);
 ret = -ENOTTY;
 }

 mutex_unlock(&tdev->lock);
 return ret;
}

/* File operations structure */
static const struct file_operations tetra_fops = {
.owner = THIS_MODULE,
.open = tetra_open,
.release = tetra_release,
.read = tetra_read,
.write = tetra_write,
.unlocked_ioctl = tetra_ioctl,
.compat_ioctl = tetra_ioctl,
.llseek = default_llseek,
};

/* ========================================================================
 * Platform Driver
 * ======================================================================== */

/**
 * tetra_probe - Platform driver probe
 */
static int tetra_probe(struct platform_device *pdev)
{
 struct tetra_device *tdev;
 struct resource *res;
 int ret;

 dev_info(&pdev->dev, "Probing TETRA char device\n");

 /* Allocate device structure */
 tdev = devm_kzalloc(&pdev->dev, sizeof(*tdev), GFP_KERNEL);
 if (!tdev)
 return -ENOMEM;

 /* Get MMIO resource */
 res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
 if (!res) {
 dev_err(&pdev->dev, "Failed to get MMIO resource\n");
 return -ENODEV;
 }

 tdev->mem_size = resource_size(res);

 /* Map registers */
 tdev->base_addr = devm_ioremap_resource(&pdev->dev, res);
 if (IS_ERR(tdev->base_addr)) {
 dev_err(&pdev->dev, "Failed to map registers\n");
 return PTR_ERR(tdev->base_addr);
 }

 dev_dbg(&pdev->dev, "MMIO: %pR (size: %pa)\n", res, &tdev->mem_size);

 /* Initialize mutex */
 mutex_init(&tdev->lock);

 /* Store device pointer */
 platform_set_drvdata(pdev, tdev);
 tetra_devices[0] = tdev;

 /* Add character device */
 cdev_init(&tdev->cdev, &tetra_fops);
 tdev->cdev.owner = THIS_MODULE;

 ret = cdev_add(&tdev->cdev, tetra_devno, 1);
 if (ret) {
 dev_err(&pdev->dev, "Failed to add cdev: %d\n", ret);
 return ret;
 }

 /* Create device node */
 tdev->dev = device_create(tetra_class, &pdev->dev,
 tetra_devno, tdev, DEVICE_NAME);
 if (IS_ERR(tdev->dev)) {
 dev_err(&pdev->dev, "Failed to create device\n");
 ret = PTR_ERR(tdev->dev);
 goto err_cdev_del;
 }

 dev_info(&pdev->dev, "TETRA char device registered at /dev/%s\n", DEVICE_NAME);
 return 0;

err_cdev_del:
 cdev_del(&tdev->cdev);
 return ret;
}

/**
 * tetra_remove - Platform driver remove
 */
static int tetra_remove(struct platform_device *pdev)
{
 struct tetra_device *tdev = platform_get_drvdata(pdev);

 dev_info(&pdev->dev, "Removing TETRA char device\n");

 device_destroy(tetra_class, tetra_devno);
 cdev_del(&tdev->cdev);

 return 0;
}

/* Device tree match table */
static const struct of_device_id tetra_of_match[] = {
 {.compatible = "midnightblue,tetra-phy", },
 { },
};
MODULE_DEVICE_TABLE(of, tetra_of_match);

/* Platform driver structure */
static struct platform_driver tetra_driver = {
.probe = tetra_probe,
.remove = tetra_remove,
.driver = {
.name = DRIVER_NAME,
.of_match_table = tetra_of_match,
 },
};

/* ========================================================================
 * Module Initialization
 * ======================================================================== */

static int __init tetra_init(void)
{
 dev_t dev;
 int ret;

 pr_info("%s: Initializing TETRA character device driver\n", DRIVER_NAME);

 /* Allocate major/minor numbers */
 ret = alloc_chrdev_region(&dev, 0, TETRA_NR_DEVS, DEVICE_NAME);
 if (ret < 0) {
 pr_err("%s: Failed to allocate chrdev region: %d\n", DRIVER_NAME, ret);
 return ret;
 }
 tetra_devno = dev;

 /* Create device class */
 tetra_class = class_create(THIS_MODULE, CLASS_NAME);
 if (IS_ERR(tetra_class)) {
 pr_err("%s: Failed to create class\n", DRIVER_NAME);
 ret = PTR_ERR(tetra_class);
 goto err_unregister_chrdev;
 }

 /* Register platform driver */
 ret = platform_driver_register(&tetra_driver);
 if (ret) {
 pr_err("%s: Failed to register platform driver: %d\n", DRIVER_NAME, ret);
 goto err_class_destroy;
 }

 pr_info("%s: Driver loaded successfully\n", DRIVER_NAME);
 return 0;

err_class_destroy:
 class_destroy(tetra_class);
err_unregister_chrdev:
 unregister_chrdev_region(tetra_devno, TETRA_NR_DEVS);

 return ret;
}

static void __exit tetra_exit(void)
{
 pr_info("%s: Exiting TETRA character device driver\n", DRIVER_NAME);

 platform_driver_unregister(&tetra_driver);
 class_destroy(tetra_class);
 unregister_chrdev_region(tetra_devno, TETRA_NR_DEVS);

 pr_info("%s: Driver unloaded\n", DRIVER_NAME);
}

module_init(tetra_init);
module_exit(tetra_exit);

/* ========================================================================
 * Module Information
 * ======================================================================== */

MODULE_AUTHOR("MidnightBlue Labs");
MODULE_DESCRIPTION("TETRA PHY/LMAC Character Device Driver");
MODULE_VERSION("0.1.0");
MODULE_LICENSE("GPL v2");
