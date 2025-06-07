#ifndef MPU6886_H_
#define MPU6886_H_

// MPU6886 sensor constants (used in Ruby implementation)

// MPU6886 I2C address
#define MPU6886_I2C_ADDRESS 0x68

// Register addresses
#define MPU6886_REG_PWR_MGMT_1    0x6B
#define MPU6886_REG_ACCEL_XOUT_H  0x3B
#define MPU6886_REG_GYRO_XOUT_H   0x43
#define MPU6886_REG_TEMP_OUT_H    0x41
#define MPU6886_REG_ACCEL_CONFIG  0x1C
#define MPU6886_REG_GYRO_CONFIG   0x1B

// Accelerometer range settings
#define MPU6886_ACCEL_RANGE_2G    0x00
#define MPU6886_ACCEL_RANGE_4G    0x08
#define MPU6886_ACCEL_RANGE_8G    0x10
#define MPU6886_ACCEL_RANGE_16G   0x18

// Gyroscope range settings
#define MPU6886_GYRO_RANGE_250DPS  0x00
#define MPU6886_GYRO_RANGE_500DPS  0x08
#define MPU6886_GYRO_RANGE_1000DPS 0x10
#define MPU6886_GYRO_RANGE_2000DPS 0x18

#endif // MPU6886_H_
