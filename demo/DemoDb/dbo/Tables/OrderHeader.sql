CREATE TABLE [dbo].[OrderHeader]
(
    [OrderId]     BIGINT         IDENTITY (1, 1) NOT NULL,
    [CustomerId]  INT            NOT NULL,
    [OrderedUtc]  DATETIME2 (3)  CONSTRAINT [DF_OrderHeader_OrderedUtc] DEFAULT (SYSUTCDATETIME()) NOT NULL,
    [TotalAmount] DECIMAL (18, 4) NOT NULL,
    CONSTRAINT [PK_OrderHeader] PRIMARY KEY CLUSTERED ([OrderId] ASC),
    CONSTRAINT [FK_OrderHeader_Customer] FOREIGN KEY ([CustomerId]) REFERENCES [dbo].[Customer] ([CustomerId])
);
GO
CREATE NONCLUSTERED INDEX [IX_OrderHeader_CustomerId_OrderedUtc]
    ON [dbo].[OrderHeader] ([CustomerId] ASC, [OrderedUtc] DESC);
