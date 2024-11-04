# AsuraMQ

Lord's protocol of AMQP-091-based message broker written in pure Zig. Hope this works someday.


## List of supported AMQP 091 "classes" and "methods"
Sorry for the OOP it was not my idea to do the NETWORK PROTOCOL this way.

#### Class Connection:
- [x] connection.start
- [x] connection.start_ok
- [x] connection.tune
- [x] connection.tune_ok
- [x] connection.open
- [x] connection.open_ok
- [ ] connection.close
#### Class Channel:
- [x] channel.open
- [x] channel.open_ok
- [ ] channel.close
#### Class Queue:
- [x] queue.declare
- [x] queue.declare_ok
#### Class Basic:
- [x] basic.qos
- [x] basic.qos_ok
- [x] basic.consume
- [x] basic.consume_ok
- [ ] basic.cancel
- [ ] basic.deliver
- [ ] basic.publish
- [ ] basic.get
- [ ] basic.ack
- [ ] basic.reject (nack)
- [ ] basic.recover-async
- [ ] basic.recover

## Референсы
- [Spec](https://www.rabbitmq.com/amqp-0-9-1-protocol)
- [Full reference](https://www.rabbitmq.com/resources/specs/amqp0-9-1.pdf)
- [python client library](https://github.com/pika/pika) (used for reference client)
