CREATE TABLE [dbo].[Customer]
(
    [CustomerId]  INT            IDENTITY (1, 1) NOT NULL,
    [ExternalRef] NVARCHAR (64)  NOT NULL,
    [DisplayName] NVARCHAR (200) NOT NULL,
    [CreatedUtc]  DATETIME2 (3)  CONSTRAINT [DF_Customer_CreatedUtc] DEFAULT (SYSUTCDATETIME()) NOT NULL,
    CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([CustomerId] ASC),
    CONSTRAINT [UQ_Customer_ExternalRef] UNIQUE NONCLUSTERED ([ExternalRef] ASC)
);
